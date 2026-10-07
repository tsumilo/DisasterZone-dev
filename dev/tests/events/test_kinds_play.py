"""Events part 2, played: every example of B:Examples() run live by a guild of 4-9 clients, end to end, through the
real inputs (duels in CHAT_MSG_SYSTEM, positions, clicks, emotes, loot and fish, prompts answered with
Live:AnswerAsk2, buttons pressed with Live:Press), and then the outcome checked on every client: the state, scores,
tags, the result saved and synced, badges and Season points when ranked, the banners and tells the right players got
(and the others didn't), the one guild post, and what each client's tracker and board read (the me-API, the board's
view). Then the same examples with trouble: the host's /reload, a takeover, players leaving or going offline, two
events at once, sign-ups at the limit, an entrant in an instance, clock skew, demo mode and practice.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_play.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
NAGRAND = 1951
YD = 1.0 / 5525.0       # one yard east-west on the mock's Nagrand map
YDY = 1.0 / 3683.33     # one yard north-south
NAMES = ["Gina", "Bert", "Cora", "Dain", "Eve", "Finn", "Hana", "Ivo", "Wade"]


def K(n):
    return n + "-Thunderstrike"


def short(k):
    return k.split("-")[0] if isinstance(k, str) else k


def guild(names, tick=HELLO, **kw):
    """A guild of clients (the first one the GM: she hosts), all logged in and synced."""
    w = World(**kw)
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, {c.name: c for c in cs}, cs


BUILD = r"""
local B = ns.EventBlocks
local N, C, J, If, T, V = B.Build.N, B.Build.C, B.Build.J, B.Build.If, B.Build.T, B.Build.V
local function shorten(sec, name)   -- (timers of the examples run for minutes: `name` only, or every one)
  B:EachScript(d, function(s)
    B:Walk(s.top, function(p) if p.k == 'tm.start' and (not name or p.a[2] == name) then p.a[1] = sec end end)
  end)
end
local function waits(sec)   -- every "wait" piece
  B:EachScript(d, function(s) B:Walk(s.top, function(p) if p.k == 'tm.wait' then p.a[1] = sec end end) end)
end
local function asktime(aid, sec) d.asks[aid].time = sec end
"""


def arrive(w, players, occ):
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in players), timeout=120, step=0.5)


def schedule(w, host, players, key, setup="", ranked=False, at=30):
    """The host saves example `key` (setup: Lua on `d` first), ranks it (she's the GM) when asked, schedules it and
    the players sign up (the host is in it already). Not started. Returns occId."""
    occ = host.eval("local d = ns.EventBlocks:Example(...)\nassert(d, 'no example')\nd.id, d.by = nil, nil\n" + BUILD
                    + setup + """
        local probs = ns.EventBlocks:Problems(d)
        assert(#probs == 0, 'problems: ' .. tostring(probs[1] and probs[1].text))
        assert(ns.Events:SaveDef(d), 'save')
        if %s then assert(ns.Events:Review(d.id, true), 'rank') end
        return ns.Events:Schedule(d.id, GetServerTime() + %d)""" % ("true" if ranked else "false", at), key)
    assert occ, "schedule"
    w.tick(3)
    arrive(w, players, occ)
    for c in players:
        ok = c.eval_py("return { ns.Events:SignUp(...) }", occ, True)
        assert ok[0] is True, (c.name, ok)
    w.tick(3)
    return occ


def start(w, host, occ):
    ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(3)


LISTEN = r"""
T_got = {}
for _, m in ipairs({ 'EVENT_SHOW', 'EVENT_TELL', 'EVENT_SOUND', 'EVENT_COUNTDOWN' }) do
  ns:On(m, function(occ, text) T_got[#T_got + 1] = { m, occ, text } end)
end
"""


def listen(*cs):
    for c in cs:
        c.eval(LISTEN)


def got(c, kind=None, occ=None):
    out = [tuple(x) for x in (c.eval_py("return T_got") or [])]
    return [x[2] for x in out if (kind is None or x[0] == kind) and (occ is None or x[1] == occ)]


def st(c, occ, path="", *args):
    """A part of the state this client knows (host: its run; others: the last state heard)."""
    return c.eval_py("local st = ns.EventLive:GetState(...)\nreturn st" + (" and st." + path if path else ""), occ, *args)


def hst(host, occ, path):
    """A part of the host's own run state (host-only parts too)."""
    return host.eval_py("local h = ns.EventLive:_State()[...]\nreturn h and h.run.st." + path, occ)


def hrun(host, occ, code, *args):
    """Lua on the host's run (`run`, `st`)."""
    return host.eval_py("local occ = ...\nlocal run = ns.EventLive:_State()[occ].run\nlocal st = run.st\n" + code, occ, *args)


def result(c, occ):
    return c.eval_py("""local r = ns.Events:GetResult(...)
        if not r then return nil end
        local o = { champ = r.champ, second = r.second, third = r.third, ranked = r.ranked or false, n = r.n,
          points = r.points, badges = {}, scores = {}, tags = {}, moments = {}, cancel = r.cancel or false, by = r.by }
        for _, b in ipairs(r.badges or {}) do o.badges[#o.badges + 1] = b.p .. ':' .. b.n end
        table.sort(o.badges)
        for _, s in ipairs(r.scores or {}) do o.scores[s.n] = s.v end
        for _, t in ipairs(r.tags or {}) do o.tags[t.n] = t.k end
        for _, m in ipairs(r.moments or {}) do o.moments[#o.moments + 1] = m.text end
        return o""", occ)


def guild_posts(w, n0=0):
    return [e["text"] for e in w.chat_log[n0:] if e["chat_type"] == "GUILD"]


def me_api(c, occ):
    """What this client's tracker and prompts read: tags, scores, buttons, asks, the arrow, the feed, the board view."""
    return c.eval_py("""local occ = ...
        local L = ns.EventLive
        local o = { tags = {}, scores = {}, buttons = L:MyButtons(occ), asks = {}, feed = {} }
        for _, t in ipairs(L:MyTags(occ)) do o.tags[#o.tags + 1] = t.n end
        for _, s in ipairs(L:MyScores(occ)) do o.scores[s.name] = { n = s.n, place = s.place or false } end
        for _, a in ipairs(L:MyAsks(occ)) do o.asks[#o.asks + 1] = { id = a.id, q = a.q, kind = a.kind, answered = a.answered } end
        for _, e in ipairs(L:MyFeed(occ)) do o.feed[#o.feed + 1] = e.text end
        o.point = { L:MyPoint(occ) }
        local st, def = L:GetState(occ), L:GetDef(occ)
        if st and def and ns.EventBoard and ns.EventBoard.Views then
          local ok, v = pcall(ns.EventBoard.Views, ns.EventBoard, def, st)
          o.layout = ok and v and v.layout or tostring(v)
        end
        return o""", occ)


def everyone(cs, fn):
    for c in cs:
        fn(c)


def standings(c):
    return c.eval_py("local o = {}; for _, r in ipairs(ns.Events:Standings()) do o[r.key] = r.pts end; return o") or {}


# ------------------------------------------------------------------------------------------------------------------
# The Friday duel cup: 8 duelists and a watcher, ranked
# ------------------------------------------------------------------------------------------------------------------
def duel(w, by, winner, loser):
    """A duel ends: both duelists' games print it (each tells the host)."""
    text = "%s has defeated %s in a duel" % (winner, loser)
    by[winner].fire("CHAT_MSG_SYSTEM", text)
    by[loser].fire("CHAT_MSG_SYSTEM", text)


def playing(host, occ):
    return hrun(host, occ, """local out = {}
        local bk = run:MainBracket()
        for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
          local m = bk.m[mid]
          if m.st == 'play' then out[#out + 1] = { mid, m.a, m.b, m.bo, m.wa, m.wb } end
        end
        return out""") or []


@case
def duel_cup_played_by_eight_duelists():
    names = NAMES[:9]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    players = [by[n] for n in names[1:8]]
    occ = schedule(w, g, players, "duel", "d.blocks.b2.set.seed = 'order'", ranked=True)
    assert g.eval("return ns.Events:GetOcc(...).ranked", occ) is True
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    # sign-up closes as it starts: the bracket, 8 seeds in sign-up order (the host first)
    seeds = [short(k) for k in hrun(g, occ, "return run:MainBracket().seeds")]
    assert seeds == names[:8], seeds
    assert st(g, occ, "stage") == "s2"
    # everyone's tracker: their match; the watcher's board: the bracket
    m = by["Bert"].eval_py("local m = ns.EventLive:MyMatch(...); return m and { m.a, m.b, m.st }", occ)
    assert m and K("Bert") in m[:2], m
    assert me_api(wade, occ)["layout"] == "bracket", me_api(wade, occ)
    # play it: the better seed wins every match, but Hana (seed 7) knocks out Bert (seed 2)
    seed = {n: i + 1 for i, n in enumerate(seeds)}
    games = 0
    for guard in range(80):
        if st(g, occ, "phase") != "live":
            break
        ms = playing(g, occ)
        if not ms:
            w.tick(2)
            continue
        for mid, a, b, bo, wa, wb in ms:
            a, b = short(a), short(b)
            win, lose = (a, b) if seed[a] < seed[b] else (b, a)
            if {a, b} == {"Bert", "Hana"}:
                win, lose = "Hana", "Bert"
            duel(w, by, win, lose)
            games += 1
        w.tick(5)   # (two reports of one pair within 3 s are one duel: no duel is that short)
    w.tick(5)
    s = st(g, occ)
    assert s["phase"] == "done" and s["stage"] == "s4", (s["phase"], s["stage"])
    # 4 quarter-finals and 2 semis best of 3, final and bronze best of 5: 2 games each, 3 in the last two
    assert games == 6 * 2 + 2 * 3, games
    # the winners: Gina beats Cora in the final, Dain beats Hana for the bronze
    for c in cs:
        r = result(c, occ)
        assert r and r["champ"] == K("Gina") and r["second"] == K("Cora") and r["third"] == K("Dain"), (c.name, r)
        assert r["ranked"] is True and r["n"] == 8, (c.name, r)
        assert r["badges"] == sorted([K("Gina") + ":Duel champion", K("Cora") + ":Runner-up", K("Dain") + ":Third place",
                                      K("Hana") + ":Giant slayer"]), (c.name, r["badges"])
        # 5 for playing, 5 a match won, 50 / 30 / 20 for the places, 10 for the giant slayer
        assert r["points"] == {K("Gina"): 70, K("Cora"): 45, K("Dain"): 35, K("Hana"): 20, K("Bert"): 5,
                               K("Eve"): 5, K("Finn"): 5, K("Ivo"): 5}, (c.name, r["points"])
        assert "Hana beats Bert 2-0" in r["moments"], r["moments"]
        assert standings(c).get(K("Gina")) == 70, (c.name, standings(c))
        # banners: the upset and the final, to the eight entrants only
        shown = got(c, "EVENT_SHOW", occ)
        want = [] if c is wade else ["Upset! Hana knocks out Bert", "Final: Gina vs Cora"]
        assert shown == want, (c.name, shown)
        # the countdown before the finals, to the entrants
        assert bool(got(c, "EVENT_COUNTDOWN", occ)) == (c is not wade), (c.name, got(c, "EVENT_COUNTDOWN", occ))
        assert got(c, "EVENT_TELL", occ) == [], (c.name, got(c, "EVENT_TELL", occ))
    # one guild post: the champion
    assert guild_posts(w, n0) == ["Gina wins the Friday duel cup!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Hide and seek in Nagrand: five players, a watcher
# ------------------------------------------------------------------------------------------------------------------
HALAA = (0.415, 0.47)


def at(w, c, dx=0, dy=0, sub="Halaa"):
    """c stands dx yards east, dy yards south of the middle of Halaa (the examples' play area)."""
    w.set_position(c, NAGRAND, HALAA[0] + dx * YD, HALAA[1] + dy * YDY, subzone=sub)


def tags_of(host, occ, tid):
    return sorted(short(k) for k in (hst(host, occ, "tags." + tid) or {}))


@case
def hide_and_seek_played_by_five():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    entrants = [by[n] for n in names[:5]]
    for i, c in enumerate(cs):
        at(w, c, i * 4)
        c.eval("SetCVar('nameplateShowFriends', '1')")
    occ = schedule(w, g, entrants[1:], "hide", "shorten(20, 'Hide'); shorten(90, 'Seek')")
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    assert st(g, occ, "stage") == "s2"
    seekers, hiders = tags_of(g, occ, "tg2"), tags_of(g, occ, "tg1")
    assert len(seekers) == 1 and len(hiders) == 4 and seekers[0] not in hiders, (seekers, hiders)
    seeker = by[seekers[0]]
    hcs = [by[n] for n in hiders]
    # who hides and who seeks: on their screens, and in their trackers
    for c in entrants:
        shown = got(c, "EVENT_SHOW", occ)
        if c is seeker:
            assert shown == ["You seek. Wait for the timer, then click the hiders you find."], shown
            assert me_api(c, occ)["tags"] == ["Seekers"], me_api(c, occ)
        else:
            assert shown == ["Hide in the play area! The seekers come in 3 minutes."], (c.name, shown)
            assert me_api(c, occ)["tags"] == ["Hiders"], (c.name, me_api(c, occ))
    assert got(wade, "EVENT_SHOW", occ) == []
    # every board: a column a tag (the watcher's too)
    assert me_api(wade, occ)["layout"] == "columns", me_api(wade, occ)
    # a hider wanders off: told to go back, and pointed there (700 yards to go)
    far = hcs[0]
    at(w, far, 700, 0, "Sunspring Post")
    w.tick(5)
    m = me_api(far, occ)
    assert m["feed"][0] == "Go back to the play area" and m["point"][0] == "pc1" and abs(m["point"][1] - 700) < 3, m
    at(w, far, 30, 0)
    w.tick(3)
    assert me_api(far, occ)["point"] == [], me_api(far, occ)
    # the seek: a Hint button and no friendly nameplates for the seeker (the hiders keep theirs)
    w.tick(20)
    assert st(g, occ, "stage") == "s3"
    w.tick(2)
    assert me_api(seeker, occ)["buttons"] == ["Hint"]
    assert seeker.eval("return GetCVar('nameplateShowFriends')") == "0"
    assert all(h.eval("return GetCVar('nameplateShowFriends')") == "1" for h in hcs)
    for c in entrants:
        assert got(c, "EVENT_SHOW", occ)[-1] == "Seek! 20 minutes.", (c.name, got(c, "EVENT_SHOW", occ))
    # the hiders spread out, each in a subzone of their own; the Hint names the nearest one's
    at(w, seeker, 0, 0)
    for i, h in enumerate(hcs):
        at(w, h, 60 + i * 80, 0, "Spot %d" % (i + 1))
    w.tick(7)
    assert seeker.eval("return ns.EventLive:Press(..., 'Hint')", occ)
    w.tick(3)
    assert me_api(seeker, occ)["feed"][0] == "Nearest hider: Spot 1", me_api(seeker, occ)["feed"]
    # (the button comes back a minute later; meanwhile it's gone and pressing does nothing)
    assert me_api(seeker, occ)["buttons"] == [] and not seeker.eval("return ns.EventLive:Press(..., 'Hint')", occ)
    # a /target macro finds no one, and says so; a click from far away doesn't count either
    seeker.eval("__MOCK.target_player(...)", hcs[1].name)
    w.tick(4)
    assert me_api(seeker, occ)["feed"][0] == "Click them to find them. Macros don't count", me_api(seeker, occ)["feed"]
    seeker.eval("__MOCK.click_player(...)", hcs[2].name)
    w.tick(3)
    assert tags_of(g, occ, "tg3") == []
    # finds: up close, three of them; the fourth stays hidden until time is up
    for i, h in enumerate(hcs[:3]):
        at(w, seeker, 60 + i * 80 - 3, 0, "Spot %d" % (i + 1))
        w.tick(4)
        seeker.eval("__MOCK.click_player(...)", h.name)
        w.tick(4)
        assert h.name in tags_of(g, occ, "tg3"), (h.name, tags_of(g, occ, "tg3"))
    # the hiders left were told each find
    last = hcs[3]
    assert [x for x in got(last, "EVENT_TELL", occ) if x.endswith(" was found")] == \
        ["%s was found" % h.name for h in hcs[:3]], got(last, "EVENT_TELL", occ)
    assert me_api(seeker, occ)["scores"]["Finds"] == {"n": 3, "place": 1}, me_api(seeker, occ)["scores"]
    # the Hint is back after its minute
    w.run_until(lambda: me_api(seeker, occ)["buttons"] == ["Hint"], timeout=70, step=1)
    # time's up: the last hider hid the longest
    w.run_until(lambda: st(g, occ, "phase") == "done", timeout=120, step=1)
    w.tick(5)
    assert seeker.eval("return GetCVar('nameplateShowFriends')") == "1"
    for c in cs:
        r = result(c, occ)
        assert r and r["champ"] == K(seeker.name) and r["ranked"] is False and r["points"] == {}, (c.name, r)
        assert r["scores"]["Finds"] == {K(seeker.name): 3}, (c.name, r["scores"])
        hid = r["scores"]["Hidden"]
        assert len(hid) == 4 and max(hid, key=hid.get) == K(last.name) and hid[K(last.name)] == 90, (c.name, hid)
        assert sorted(r["tags"]["Found"]) == sorted(K(h.name) for h in hcs[:3]), r["tags"]
        assert r["tags"]["Hiders"] == [K(last.name)], r["tags"]
        assert len(r["moments"]) == 3 and r["moments"][0] == "%s found %s" % (seeker.name, hcs[0].name), r["moments"]
    assert guild_posts(w, n0) == ["%s stayed hidden the longest in hide and seek!" % last.name], guild_posts(w, n0)
    # the watcher was told nothing, shown nothing
    assert got(wade) == [], got(wade)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Infection: five players
# ------------------------------------------------------------------------------------------------------------------
@case
def infection_played_by_five():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    entrants = [by[n] for n in names[:5]]
    for i, c in enumerate(cs):
        at(w, c, i * 2)
    occ = schedule(w, g, entrants[1:], "infect", "shorten(15, 'Run'); shorten(300, 'Infect')")
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    zero = by[tags_of(g, occ, "tg2")[0]]
    hiders = [by[n] for n in tags_of(g, occ, "tg1")]
    assert len(hiders) == 4 and zero not in hiders
    assert got(zero, "EVENT_SHOW", occ) == ["You're infected. In 2 minutes, click the others to infect them."]
    # a touch before the infection starts counts for nothing
    zero.eval("__MOCK.click_player(...)", hiders[0].name)
    w.tick(3)
    assert tags_of(g, occ, "tg2") == [zero.name]
    w.tick(15)
    assert st(g, occ, "stage") == "s3"
    for c in entrants:
        assert got(c, "EVENT_SHOW", occ)[-1] == "The infection spreads!", c.name
    # zero infects one; the newly infected infects the next (after the 2 s a touch takes to count again)
    w.tick(3)
    zero.eval("__MOCK.click_player(...)", hiders[0].name)
    w.tick(3)
    assert got(hiders[0], "EVENT_SHOW", occ)[-1] == "You're infected! Now catch the others."
    assert me_api(hiders[0], occ)["tags"] == ["Infected"], me_api(hiders[0], occ)
    hiders[0].eval("__MOCK.click_player(...)", hiders[1].name)
    w.tick(3)
    # a hider clicking a hider: nothing
    hiders[2].eval("__MOCK.click_player(...)", hiders[3].name)
    w.tick(3)
    assert tags_of(g, occ, "tg1") == sorted([hiders[2].name, hiders[3].name]), tags_of(g, occ, "tg1")
    zero.eval("__MOCK.click_player(...)", hiders[2].name)
    w.tick(3)
    # one left: everyone is told who
    for c in entrants:
        assert "Last one standing: " + hiders[3].name in got(c, "EVENT_SHOW", occ), (c.name, got(c, "EVENT_SHOW", occ))
    w.tick(10)
    hiders[1].eval("__MOCK.click_player(...)", hiders[3].name)
    w.tick(5)
    assert st(g, occ, "phase") == "done"
    for c in cs:
        r = result(c, occ)
        inf, surv = r["scores"]["Infections"], r["scores"]["Survived"]
        assert inf == {K(zero.name): 2, K(hiders[0].name): 1, K(hiders[1].name): 1}, (c.name, inf)
        assert max(surv, key=surv.get) == K(hiders[3].name) and len(surv) == 4, (c.name, surv)
        assert r["champ"] == K(zero.name), r
        assert len(r["tags"]["Infected"]) == 5 and not r["tags"].get("Hiders"), r["tags"]
    assert guild_posts(w, n0) == [hiders[3].name + " held out the longest against the infection!"], guild_posts(w, n0)
    assert got(wade) == []
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Mount race: four riders gather, a fifth joins late, one gets off the mount; ranked
# ------------------------------------------------------------------------------------------------------------------
ROUTE = {"pc1": (0.555, 0.37), "pc2": (0.605, 0.232), "pc3": (0.43, 0.212), "pc4": (0.42, 0.452), "pc5": (0.322, 0.43),
         "pc6": (0.35, 0.722), "pc7": (0.62, 0.62), "pc8": (0.735, 0.39)}
ROUTE_ORDER = ["pc2", "pc3", "pc4", "pc5", "pc6", "pc7", "pc8", "pc1"]


def ride(w, c, places, gap=1.5):
    for pid in places:
        x, y = ROUTE[pid]
        w.set_position(c, NAGRAND, x, y, subzone="")
        w.tick(gap)


@case
def mount_race_played_by_five():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Wade"]
    w, by, cs = guild(names)
    g, wade, eve = by["Gina"], by["Wade"], by["Eve"]
    riders = [by[n] for n in ["Gina", "Bert", "Cora", "Dain"]]
    for i, c in enumerate(cs):
        at(w, c, i * 3)   # (in Halaa, far from the start)
    occ = schedule(w, g, riders[1:], "race", "shorten(300, 'Race')", ranked=True)
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    meet = "Meet at Garadar on a ground mount. The race starts when the host closes the sign-up."
    assert st(g, occ, "stage") == "s1"
    for c in riders:
        m = me_api(c, occ)
        assert m["feed"] == [meet] and m["point"][0] == "pc1" and m["point"][1] > 500, (c.name, m)
    # Eve joins while the sign-up is open: she's in, told and pointed too
    assert eve.eval_py("return { ns.Events:SignUp(..., true) }", occ)[0] is True
    w.tick(4)
    assert K("Eve") in st(g, occ, "entrants")
    assert me_api(eve, occ)["feed"] == [meet] and me_api(eve, occ)["point"][0] == "pc1", me_api(eve, occ)
    # at the start line, mounted: the arrow is done
    racers = riders + [eve]
    for c in racers:
        x, y = ROUTE["pc1"]
        w.set_position(c, NAGRAND, x, y, subzone="Garadar")
        c.eval("__MOCK.mounted = true")
    w.tick(3)
    assert all(me_api(c, occ)["point"] == [] for c in racers)
    # the board: who signed up (the race's map with it)
    assert me_api(wade, occ)["layout"] in ("signup", "race"), me_api(wade, occ)["layout"]
    # the host closes the sign-up: 10 s to count down, then "Go!" and the arrow to the first place
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ)
    w.tick(3)
    assert st(g, occ, "stage") == "s2" and tags_of(g, occ, "tg1") == sorted(c.name for c in racers)
    for c in racers:
        assert got(c, "EVENT_COUNTDOWN", occ), c.name
    w.tick(10)
    for c in racers:
        assert got(c, "EVENT_SHOW", occ) == ["Go! Follow the arrow round Nagrand."], (c.name, got(c, "EVENT_SHOW", occ))
        assert me_api(c, occ)["point"][0] == "pc2", (c.name, me_api(c, occ)["point"])
    assert got(wade) == []
    assert me_api(wade, occ)["layout"] == "race", me_api(wade, occ)["layout"]
    # Bert rides the route; a place out of turn counts for nothing (Cora rides to the third first)
    ride(w, by["Bert"], ROUTE_ORDER)
    ride(w, by["Cora"], ["pc4"])
    assert hrun(g, occ, "return run:ListPos('ls1', select(2, ...))", K("Cora")) == 1
    ride(w, by["Gina"], ROUTE_ORDER[:4])
    # Dain gets off his mount: out, told, no arrow
    by["Dain"].eval("__MOCK.mounted = false")
    w.tick(5)   # (the tell comes at once; the state with the tag and the arrow within a few seconds)
    md = me_api(by["Dain"], occ)
    assert md["feed"][0] == "You got off your mount: you're out of the race" and md["point"] == [] and md["tags"] == ["Out"], md
    ride(w, by["Gina"], ROUTE_ORDER[4:])
    ride(w, by["Cora"], ROUTE_ORDER)
    # (Bert's tracker: he finished first)
    assert me_api(by["Bert"], occ)["feed"][0] == "You finish in place 1", me_api(by["Bert"], occ)["feed"]
    assert me_api(by["Bert"], occ)["scores"]["Time"]["place"] == 1
    ride(w, eve, ROUTE_ORDER)
    w.tick(5)
    assert st(g, occ, "phase") == "done", st(g, occ, "phase")
    times = hst(g, occ, "scores.sc1")
    order = sorted(times, key=times.get)
    assert [short(k) for k in order] == ["Bert", "Gina", "Cora", "Eve"], times
    for c in cs:
        r = result(c, occ)
        assert r["champ"] == K("Bert") and r["second"] == K("Gina") and r["third"] == K("Cora"), (c.name, r)
        assert r["badges"] == sorted([K("Bert") + ":Fastest rider", K("Gina") + ":Second rider", K("Cora") + ":Third rider"]), r
        assert r["points"] == {K("Bert"): 30, K("Gina"): 20, K("Cora"): 10}, (c.name, r["points"])
        assert r["tags"]["Out"] == [K("Dain")], r["tags"]
        assert r["moments"] == ["Bert crosses the finish line", "Dain is out: off the mount", "Gina crosses the finish line",
                                "Cora crosses the finish line", "Eve crosses the finish line"], r["moments"]
        # (the arrows are gone)
        assert me_api(c, occ)["point"] == [], c.name
    assert guild_posts(w, n0) == ["Bert wins the mount race!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Fishing derby: five anglers (the host catches nothing), ranked
# ------------------------------------------------------------------------------------------------------------------
def loot_line(c, item_id, name, count=1):
    link = "|cffffffff|Hitem:%d::::::::70:::::|h[%s]|h|r" % (item_id, name)
    text = ("You receive loot: %sx%d." % (link, count)) if count > 1 else ("You receive loot: %s." % link)
    c.fire("CHAT_MSG_LOOT", text, c.full_name, "", "", c.name, "", 0, 0, "", 0, 0, c.guid, 0, False, False, False, False)


def catch(w, c, item=27422, name=None):
    """c fishes something up (a fishing loot window; by name when given: the mock calls unknown items "Item <id>")."""
    if name:
        c.eval("__MOCK.fishing_loot = true")
        c.fire("LOOT_OPENED", True, False)
        loot_line(c, item, name)
        c.eval("__MOCK.fishing_loot = false")
        c.fire("LOOT_CLOSED")
    else:
        c.eval("__MOCK.fish_loot({ { %d, 1 } })" % item)
    w.tick(1.5)


@case
def fishing_derby_played_by_five():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    entrants = [by[n] for n in names[:5]]
    occ = schedule(w, g, entrants[1:], "fish", "shorten(90, 'Derby')", ranked=True)
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    assert st(g, occ, "stage") == "s2"
    for c in cs:
        assert got(c, "EVENT_SHOW", occ) == ([] if c is wade else ["Fish! 30 minutes: every fish counts."]), c.name
    assert me_api(wade, occ)["layout"] == "scores", me_api(wade, occ)["layout"]
    b, co, d, e = by["Bert"], by["Cora"], by["Dain"], by["Eve"]
    # ore from a vein is no fish
    loot_line(b, 23424, "Fel Iron Ore", 3)
    w.tick(2)
    catch(w, b)
    catch(w, co)          # (a tie: Bert keeps the lead)
    catch(w, co)
    catch(w, b)
    catch(w, b, 27388, "Mr. Pinchy")
    catch(w, d)
    catch(w, d)
    catch(w, e)
    w.tick(4)
    leads = ["Bert leads with 1 fish", "Cora leads with 2 fish", "Bert leads with 3 fish"]
    for c in cs:
        assert got(c, "EVENT_TELL", occ) == ([] if c is wade else leads), (c.name, got(c, "EVENT_TELL", occ))
    assert me_api(d, occ)["scores"]["Fish"] == {"n": 2, "place": 2}, me_api(d, occ)["scores"]
    assert me_api(g, occ)["scores"]["Fish"] == {"n": 0, "place": False}, me_api(g, occ)["scores"]
    assert "Bert fished up Mr. Pinchy" in st(wade, occ, "moments")[0]["text"]
    w.run_until(lambda: st(g, occ, "phase") == "done", timeout=100, step=1)
    w.tick(5)
    for c in cs:
        r = result(c, occ)
        assert r["scores"]["Fish"] == {K("Bert"): 3, K("Cora"): 2, K("Dain"): 2, K("Eve"): 1}, (c.name, r["scores"])
        assert r["champ"] == K("Bert"), r
        # a tie for second: both silver, nobody third (Eve is fourth)
        assert r["badges"] == sorted([K("Bert") + ":Angler of the night", K("Cora") + ":Runner-up",
                                      K("Dain") + ":Runner-up"]), (c.name, r["badges"])
        assert r["points"] == {K("Bert"): 35, K("Cora"): 25, K("Dain"): 25, K("Eve"): 5}, (c.name, r["points"])
    assert guild_posts(w, n0) == ["Bert wins the fishing derby with 3 fish!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Transmog contest: the host picks two judges, five models on the catwalk, everyone votes; ranked
# ------------------------------------------------------------------------------------------------------------------
def answer(c, occ, aid, v):
    return c.eval("return ns.EventLive:AnswerAsk2(...)", occ, aid, v)


def open_ask(c, occ, aid):
    """The open ask this client's prompt shows (id, question), or None."""
    for a in me_api(c, occ)["asks"]:
        if a["id"] == aid and not a["answered"]:
            return a
    return None


@case
def transmog_contest_played_by_five():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    entrants = [by[n] for n in names[:5]]
    occ = schedule(w, g, entrants[1:], "tmog", "asktime('ak1', 40); asktime('ak2', 30); asktime('ak3', 40)", ranked=True)
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    assert st(g, occ, "stage") == "s2"
    # only the host is asked who judges (a prompt of players, up to three); the others see no prompt
    w.tick(2)
    a = open_ask(g, occ, "ak1")
    assert a and a["q"] == "Who judges? Pick up to 3" and a["kind"] == "player", me_api(g, occ)
    assert all(open_ask(c, occ, "ak1") is None for c in entrants[1:])
    # (a fourth pick is too many: refused before it's sent)
    assert answer(g, occ, "ak1", [K("Bert"), K("Cora"), K("Dain"), K("Eve")]) is False
    assert answer(g, occ, "ak1", [K("Bert"), K("Cora")]) is True
    w.tick(4)
    assert tags_of(g, occ, "tg1") == ["Bert", "Cora"]
    for c in cs:
        assert got(c, "EVENT_SHOW", occ)[:1] == ([] if c is wade else ["The judges: Bert, Cora"]), (c.name, got(c, "EVENT_SHOW", occ))
    # the catwalk: each model in turn (sign-up order), the judges score 1 to 10; a judge's own outfit doesn't count
    marks = {"Gina": (6, 7), "Bert": (10, 9), "Cora": (8, 10), "Dain": (9, 9), "Eve": (4, 5)}
    for model in ["Gina", "Bert", "Cora", "Dain", "Eve"]:
        w.run_until(lambda: open_ask(by["Bert"], occ, "ak2") is not None, timeout=20, step=0.5)
        q = open_ask(by["Bert"], occ, "ak2")["q"]
        assert q == "Score %s's outfit, 1 to 10" % model, q
        # (non-judges aren't asked; 11 isn't a score)
        assert open_ask(by["Dain"], occ, "ak2") is None
        assert answer(by["Bert"], occ, "ak2", 11) is False
        assert answer(by["Bert"], occ, "ak2", marks[model][0]) is True
        assert answer(by["Bert"], occ, "ak2", 3) is False   # (one answer each)
        assert answer(by["Cora"], occ, "ak2", marks[model][1]) is True
        w.tick(3)
    w.tick(3)
    for c in entrants:
        assert [x for x in got(c, "EVENT_SHOW", occ) if x.endswith("on the catwalk")] == \
            ["%s is on the catwalk" % n for n in ["Gina", "Bert", "Cora", "Dain", "Eve"]], (c.name, got(c, "EVENT_SHOW", occ))
    assert hst(g, occ, "scores.sc1") == {K("Gina"): 13, K("Bert"): 9, K("Cora"): 8, K("Dain"): 18, K("Eve"): 9}, \
        hst(g, occ, "scores.sc1")
    # the vote: everyone, up to three each, never oneself
    assert st(g, occ, "stage") == "s4"
    w.tick(2)
    assert answer(g, occ, "ak3", [K("Gina")]) is False
    votes = {"Gina": ["Dain"], "Bert": ["Dain", "Gina"], "Cora": ["Gina"], "Dain": ["Gina", "Eve"], "Eve": ["Dain"]}
    for n, picks in votes.items():
        assert open_ask(by[n], occ, "ak3") is not None, n
        assert answer(by[n], occ, "ak3", [K(p) for p in picks]) is True, n
        w.tick(1)
    w.tick(5)
    assert st(g, occ, "phase") == "done", st(g, occ, "phase")
    # Dain and Gina have three votes each: Dain was picked first, he wore it best (+5)
    for c in cs:
        r = result(c, occ)
        assert r["scores"]["Votes"] == {K("Gina"): 13, K("Bert"): 9, K("Cora"): 8, K("Dain"): 23, K("Eve"): 9}, (c.name, r)
        assert r["champ"] == K("Dain") and r["second"] == K("Gina"), r
        # Bert and Eve tie for third: both bronze
        assert r["badges"] == sorted([K("Dain") + ":Best dressed", K("Gina") + ":Runner-up", K("Bert") + ":Third place",
                                      K("Eve") + ":Third place"]), (c.name, r["badges"])
        assert r["points"] == {K("Dain"): 30, K("Gina"): 20, K("Bert"): 10, K("Eve"): 10}, (c.name, r["points"])
        assert got(c, "EVENT_SHOW", occ)[-1:] == ([] if c is wade else ["Dain wore it best"]), c.name
    assert guild_posts(w, n0) == ["Dain wins the transmog contest!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Trivia night: four players type their answers, a watcher
# ------------------------------------------------------------------------------------------------------------------
QUIZ = [("Which zone is Halaa in?", "Nagrand"), ("What's the highest level in The Burning Crusade?", "70"),
        ("Who leads the Mag'har at Garadar?", "Garrosh"), ("Which boss drops the Ashes of Al'ar?", "Kael'thas"),
        ("Who is the last boss of Karazhan?", "Malchezaar"), ("Which city do the Aldor and the Scryers share?", "Shattrath"),
        ("Which naaru leads the Sha'tar?", "A'dal"), ("What do you fish up in Skettis that grants wishes?", "Mr. Pinchy"),
        ("Which faction gives the Cenarion War Hippogryph?", "Cenarion Expedition"),
        ("Which zone has the Ring of Blood?", "Nagrand")]


@case
def trivia_night_played_by_four():
    names = ["Gina", "Bert", "Cora", "Dain", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    entrants = [by[n] for n in names[:4]]
    occ = schedule(w, g, entrants[1:], "quiz", "waits(1); asktime('ak1', 12)")
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    assert got(by["Cora"], "EVENT_SHOW", occ) == ["Trivia night: 10 questions, 30 seconds each. Type your answers."]
    # Gina knows them all (any capitals, spaces), Bert every other one, Cora never, Dain answers the first three only
    for i, (q, a) in enumerate(QUIZ):
        w.run_until(lambda: (open_ask(by["Bert"], occ, "ak1") or {}).get("q") == q, timeout=30, step=0.5)
        for c in entrants:
            assert (open_ask(c, occ, "ak1") or {}).get("q") == q, (c.name, i, me_api(c, occ)["asks"])
        assert answer(g, occ, "ak1", "  " + a.upper() + " ") is True
        if i == 0:
            # secret: while it's open the watcher's copy says who answered, not what
            w.run_until(lambda: (st(wade, occ, "qa.ak1.ans") or {}).get(K("Gina")) is not None, timeout=10, step=0.5)
            assert st(wade, occ, "qa.ak1.ans")[K("Gina")] is True
        assert answer(by["Bert"], occ, "ak1", a if i % 2 == 0 else "no idea") is True
        assert answer(by["Cora"], occ, "ak1", "|cffff0000no|r idea") is True
        if i < 3:
            assert answer(by["Dain"], occ, "ak1", a.lower()) is True
        w.tick(1)
    w.run_until(lambda: st(g, occ, "phase") == "done", timeout=60, step=1)
    w.tick(5)
    right = {"Gina": 10, "Bert": 5, "Dain": 3}
    for c in cs:
        tells = got(c, "EVENT_TELL", occ)
        assert tells == ["Right!"] * right.get(c.name, 0), (c.name, tells)
        r = result(c, occ)
        assert r["scores"]["Right"] == {K(n): v for n, v in right.items()}, (c.name, r["scores"])
        assert r["champ"] == K("Gina") and r["second"] == K("Bert") and r["third"] == K("Dain"), r
    assert me_api(by["Bert"], occ)["scores"]["Right"] == {"n": 5, "place": 2}
    assert me_api(by["Cora"], occ)["scores"]["Right"] == {"n": 0, "place": False}
    assert guild_posts(w, n0) == ["Gina wins trivia night!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Red light, green light: four players line up, the host closes the sign-up
# ------------------------------------------------------------------------------------------------------------------
START_LINE, FINISH_LINE = (0.405, 0.44), (0.43, 0.47)


def light(host, occ):
    return hst(host, occ, "vars.Light")


def move(c, on):
    c.eval("__MOCK.speed = %d" % (7 if on else 0))


@case
def red_light_green_light_played_by_four():
    names = ["Gina", "Bert", "Cora", "Dain", "Wade"]
    w, by, cs = guild(names)
    g, wade = by["Gina"], by["Wade"]
    b, co, d = by["Bert"], by["Cora"], by["Dain"]
    entrants = [g, b, co, d]
    for i, c in enumerate(cs):
        at(w, c, 200 + i * 3)
    occ = schedule(w, g, entrants[1:], "redlight", "shorten(150, 'Game')")
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    line = "Line up at the start line. The game starts when the host closes the sign-up."
    for c in entrants:
        m = me_api(c, occ)
        assert m["feed"] == [line] and m["point"][0] == "pc1", (c.name, m)
    for i, c in enumerate(entrants):
        w.set_position(c, NAGRAND, START_LINE[0] + i * 2 * YD, START_LINE[1], subzone="Halaa")
    w.tick(3)
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ)
    w.tick(3)
    assert st(g, occ, "stage") == "s2" and light(g, occ) == "green"
    for c in entrants:
        assert got(c, "EVENT_SHOW", occ) == ["Green light: go!"], (c.name, got(c, "EVENT_SHOW", occ))
        m = me_api(c, occ)
        assert m["point"][0] == "pc2" and m["tags"] == ["Playing"], (c.name, m)
    assert me_api(wade, occ)["layout"] == "columns", me_api(wade, occ)["layout"]
    # green: everyone walks; at "Red light!" the three stop at once, Gina keeps going
    for c in entrants:
        move(c, True)
    w.run_until(lambda: light(g, occ) == "turning", timeout=20, step=0.1)
    for c in (b, co, d):
        move(c, False)
    w.run_until(lambda: light(g, occ) == "red", timeout=5, step=0.1)
    w.tick(1)
    for c in entrants:
        assert "Red light! Stop!" in got(c, "EVENT_SHOW", occ), c.name
        assert got(c, "EVENT_SOUND", occ) == ["warning"], (c.name, got(c, "EVENT_SOUND", occ))
    assert me_api(g, occ)["feed"][0] == "You kept moving on red: you're out", me_api(g, occ)["feed"]
    assert tags_of(g, occ, "tg2") == ["Gina"] and tags_of(g, occ, "tg1") == ["Bert", "Cora", "Dain"]
    # Dain starts moving while it's red: out too
    move(d, True)
    w.tick(2)
    assert me_api(d, occ)["feed"][0] == "You moved on red: you're out", me_api(d, occ)["feed"]
    move(d, False)
    # green again: Bert and Cora walk to the finish line
    w.run_until(lambda: light(g, occ) == "green", timeout=15, step=0.2)
    for c in (b, co):
        move(c, True)
    w.tick(1)
    w.set_position(b, NAGRAND, FINISH_LINE[0], FINISH_LINE[1], subzone="Halaa")
    w.tick(2)
    assert me_api(b, occ)["feed"][0] == "You made it! Place 1", me_api(b, occ)["feed"]
    w.set_position(co, NAGRAND, FINISH_LINE[0] + 3 * YD, FINISH_LINE[1], subzone="Halaa")
    w.tick(4)
    assert st(g, occ, "phase") == "done", st(g, occ)["stage"]
    for c in cs:
        r = result(c, occ)
        fin = r["scores"]["Finish"]
        assert sorted(fin) == [K("Bert"), K("Cora")] and fin[K("Bert")] <= fin[K("Cora")], (c.name, fin)
        assert r["champ"] == K("Bert") and r["second"] == K("Cora"), r
        assert r["tags"]["Made it"] == [K("Bert"), K("Cora")] and r["tags"]["Out"] == [K("Dain"), K("Gina")], r["tags"]
        assert r["moments"] == ["Gina kept moving on red", "Dain moved on red", "Bert made it to the finish line",
                                "Cora made it to the finish line"], r["moments"]
        assert got(c) == [] if c is wade else True
    assert guild_posts(w, n0) == ["Bert wins red light, green light!"], guild_posts(w, n0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Trouble: the host's /reload, a takeover (scripts that were waiting go on where they were)
# ------------------------------------------------------------------------------------------------------------------
def wait_question(w, c, occ, q, timeout=40):
    w.run_until(lambda: (open_ask(c, occ, "ak1") or {}).get("q") == q, timeout=timeout, step=0.5)


@case
def trivia_goes_on_after_the_hosts_reload():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    occ = schedule(w, g, cs[1:], "quiz", "waits(1); asktime('ak1', 25)")
    listen(*cs)
    n0 = len(w.chat_log)
    start(w, g, occ)
    for i, (q, a) in enumerate(QUIZ[:3]):
        wait_question(w, b, occ, q)
        for c in cs:
            assert answer(c, occ, "ak1", a) is True
        w.tick(1)
    # question 4: Gina (the host) answers, then reloads; Bert answers while she's away (his answer reaches nobody)
    q4, a4 = QUIZ[3]
    wait_question(w, b, occ, q4)
    assert answer(g, occ, "ak1", a4) is True
    w.tick(3)
    g.relog()
    listen(g)
    assert answer(b, occ, "ak1", a4) is True
    w.tick(6)
    # she's back with the run: question 4 still open with her answer kept (a secret one, from her own disk); Bert's
    # answer was sent again once her state said it wasn't there
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ)
    w.tick(3)
    assert st(g, occ, "qa.ak1.q") == q4 and st(g, occ, "qa.ak1.open") is True, st(g, occ, "qa.ak1")
    ans = st(g, occ, "qa.ak1.ans")
    assert ans[K("Gina")] == a4 and ans[K("Bert")] == a4, ans
    assert open_ask(co, occ, "ak1")["q"] == q4
    assert answer(co, occ, "ak1", a4) is True and answer(d, occ, "ak1", "no idea") is True
    # the quiz goes on: questions 5 to 10, once each
    for i, (q, a) in enumerate(QUIZ[4:]):
        wait_question(w, b, occ, q)
        for c in cs:
            assert answer(c, occ, "ak1", a if c is not d else "no idea") is True
        w.tick(1)
    w.run_until(lambda: st(g, occ, "phase") == "done", timeout=60, step=1)
    w.tick(5)
    for c in cs:
        r = result(c, occ)
        assert r["scores"]["Right"] == {K("Gina"): 10, K("Bert"): 10, K("Cora"): 10, K("Dain"): 3}, (c.name, r["scores"])
        # (Gina's own tells since her reload: questions 5 to 10)
        tells = got(c, "EVENT_TELL", occ)
        assert tells.count("Right!") == {"Dain": 3, "Gina": 6}.get(c.name, 10), (c.name, tells)
    # every question asked once: the restored run's log has question 4 waited on, 5 to 10 asked
    asked = hrun(g, occ, "local o = {}; for _, l in ipairs(run.log) do if l.kind == 'ask' and l.text:find('^Asks') "
                         "then o[#o + 1] = l.text end end; return o")
    assert [a.split(': ', 1)[1] for a in asked] == [q for q, _ in QUIZ[4:]], asked
    assert guild_posts(w, n0) == ["Gina wins trivia night!"], guild_posts(w, n0)
    w.assert_no_errors()


@case
def trivia_goes_on_after_a_takeover():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    occ = schedule(w, g, cs[1:], "quiz", "waits(1); asktime('ak1', 25)")
    listen(*cs)
    start(w, g, occ)
    for i, (q, a) in enumerate(QUIZ[:2]):
        wait_question(w, b, occ, q)
        for c in cs:
            assert answer(c, occ, "ak1", a) is True
        w.tick(1)
    # question 3: Gina and Cora answer (secret: the state the others have says only that they did), then the host
    # is gone for good
    q3, a3 = QUIZ[2]
    wait_question(w, b, occ, q3)
    assert answer(g, occ, "ak1", a3) is True and answer(co, occ, "ak1", "Thrall") is True
    w.tick(4)
    g.logout()
    # Bert answers meanwhile (to nobody); Bert takes over once Gina has been quiet for 50 s (she's offline)
    assert answer(b, occ, "ak1", a3) is True
    w.run_until(lambda: b.eval("return ns.EventLive:IsHostOf(...)", occ), timeout=90, step=1)
    w.tick(2)
    # question 3's answers before the takeover are known as given, not what they were: not counted again, not
    # anyone's answer; the question closed (its time was up) and the quiz goes on from question 4
    q = hst(b, occ, "qa.ak1")
    assert q["q"] != q3 or q["open"] is False, q
    for i, (qq, a) in enumerate(QUIZ[3:]):
        wait_question(w, co, occ, qq)
        for c in (b, co, d):
            assert answer(c, occ, "ak1", a) is True, (c.name, i)
        w.tick(1)
    w.run_until(lambda: st(b, occ, "phase") == "done", timeout=80, step=1)
    w.tick(5)
    for c in (b, co, d):
        r = result(c, occ)
        assert r and r["by"] == K("Bert"), (c.name, r)
        # Gina: questions 1-3; Bert all ten (his answer to 3, sent to the host who was gone, counts once he runs it);
        # Cora 1, 2, 4-10 (her wrong answer to 3 isn't known any more); Dain 1, 2, 4-10
        assert r["scores"]["Right"] == {K("Gina"): 3, K("Bert"): 10, K("Cora"): 9, K("Dain"): 9}, (c.name, r["scores"])
    w.assert_no_errors()


@case
def transmog_catwalk_goes_on_after_the_hosts_reload():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    occ = schedule(w, g, cs[1:], "tmog", "asktime('ak1', 40); asktime('ak2', 40); asktime('ak3', 40)")
    listen(*cs)
    start(w, g, occ)
    w.tick(2)
    assert answer(g, occ, "ak1", [K("Bert"), K("Cora")]) is True
    for model in ["Gina", "Bert"]:
        w.run_until(lambda: (open_ask(b, occ, "ak2") or {}).get("q") == "Score %s's outfit, 1 to 10" % model, timeout=20,
                    step=0.5)
        assert answer(b, occ, "ak2", 7) is True and answer(co, occ, "ak2", 8) is True
        w.tick(3)
    # Cora on the catwalk: Bert scores her, then the host reloads
    w.run_until(lambda: (open_ask(b, occ, "ak2") or {}).get("q") == "Score Cora's outfit, 1 to 10", timeout=20, step=0.5)
    assert answer(b, occ, "ak2", 9) is True
    w.tick(3)
    g.relog()
    w.tick(8)
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ)
    # the same question, still open; Cora's score of her own outfit counts for nothing, as before
    assert open_ask(co, occ, "ak2")["q"] == "Score Cora's outfit, 1 to 10"
    assert answer(co, occ, "ak2", 10) is True
    w.tick(3)
    w.run_until(lambda: (open_ask(b, occ, "ak2") or {}).get("q") == "Score Dain's outfit, 1 to 10", timeout=20, step=0.5)
    assert answer(b, occ, "ak2", 5) is True and answer(co, occ, "ak2", 6) is True
    w.tick(3)
    # the vote, then prizes
    assert st(g, occ, "stage") == "s4"
    for c, pick in ((g, "Cora"), (b, "Cora"), (co, "Gina"), (d, "Cora")):
        assert answer(c, occ, "ak3", [K(pick)]) is True, c.name
    w.tick(5)
    assert st(g, occ, "phase") == "done"
    # each model on the catwalk was shown once
    walks = [x for x in got(d, "EVENT_SHOW", occ) if x.endswith("on the catwalk")]
    assert walks == ["%s is on the catwalk" % n for n in names], walks
    assert result(d, occ)["scores"]["Votes"] == {K("Gina"): 15, K("Bert"): 8, K("Cora"): 14, K("Dain"): 11}, \
        result(d, occ)["scores"]
    w.assert_no_errors()


@case
def the_hint_comes_back_after_the_hosts_reload():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g = cs[0]
    for i, c in enumerate(cs):
        at(w, c, i * 30, 0, "Spot %d" % i)
    occ = schedule(w, g, cs[1:], "hide", "shorten(5, 'Hide'); shorten(600, 'Seek')")
    start(w, g, occ)
    w.tick(8)
    assert st(g, occ, "stage") == "s3"
    seeker = by[tags_of(g, occ, "tg2")[0]]
    w.tick(2)
    assert seeker.eval("return ns.EventLive:Press(..., 'Hint')", occ)
    w.tick(3)
    assert me_api(seeker, occ)["buttons"] == []
    g.relog()
    w.tick(20)
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ)
    assert me_api(seeker, occ)["buttons"] == []
    # a minute after the press: back
    w.run_until(lambda: me_api(seeker, occ)["buttons"] == ["Hint"], timeout=50, step=1)
    w.assert_no_errors()


@case
def the_race_countdown_and_the_red_light_survive_the_hosts_reload():
    names = ["Gina", "Bert", "Cora"]
    w, by, cs = guild(names)
    g, b, co = cs
    # the race: at Garadar, mounted; the host reloads during the countdown's 10 s
    for c in cs:
        w.set_position(c, NAGRAND, ROUTE["pc1"][0], ROUTE["pc1"][1], subzone="Garadar")
        c.eval("__MOCK.mounted = true")
    occ = schedule(w, g, cs[1:], "race")
    listen(*cs)
    start(w, g, occ)
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ)
    w.tick(3)
    assert st(g, occ, "stage") == "s2" and me_api(b, occ)["point"] == []
    g.relog()
    w.tick(12)
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ)
    for c in (b, co):
        assert got(c, "EVENT_SHOW", occ) == ["Go! Follow the arrow round Nagrand."], (c.name, got(c, "EVENT_SHOW", occ))
        assert me_api(c, occ)["point"][0] == "pc2", (c.name, me_api(c, occ)["point"])
    # (the riders still in Garadar are known to be there: their games told the host again after its reload)
    assert sorted(hst(g, occ, "inplace.pc1") or {}) == sorted(K(n) for n in names), hst(g, occ, "inplace")
    g.eval("ns.EventLive:EndEvent(...)", occ)
    w.tick(3)
    # red light: the host reloads while the light turns red (the 2 s wait); it turns red, and on
    occ2 = schedule(w, g, cs[1:], "redlight", "shorten(300, 'Game')")
    start(w, g, occ2)
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ2)
    w.run_until(lambda: light(g, occ2) == "turning", timeout=20, step=0.1)
    move(g, False)
    g.relog()
    w.tick(8)
    assert g.eval("return ns.EventLive:IsHostOf(...)", occ2)
    w.run_until(lambda: light(g, occ2) == "green", timeout=20, step=0.5)
    assert tags_of(g, occ2, "tg1") == ["Bert", "Cora", "Gina"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Trouble: players who leave, go offline and come back
# ------------------------------------------------------------------------------------------------------------------
@case
def a_duelist_who_goes_offline_is_told_to_the_host_loses_by_no_show_and_comes_back():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    occ = schedule(w, g, cs[1:], "duel", "d.blocks.b2.set.seed = 'order'; d.blocks.b2.set.noshow = 20")
    listen(*cs)
    start(w, g, occ)
    # semi-finals: Gina vs Dain, Bert vs Cora. Dain's game goes away
    d.logout()
    w.tick(5)
    assert me_api(g, occ)["feed"][0] == "Dain went offline", me_api(g, occ)["feed"]
    assert got(b, "EVENT_TELL", occ) == []   # (told to the host only)
    # Gina is ready; Dain doesn't show in time: hers by no-show
    g.eval("ns.EventLive:Ready(...)", occ)
    duel(w, by, "Bert", "Cora")
    w.tick(5)
    duel(w, by, "Bert", "Cora")
    w.tick(25)
    ms = hrun(g, occ, "local o = {} local bk = run:MainBracket() for _, mid in ipairs(bk.rounds[1]) do local m = bk.m[mid] "
                      "o[#o + 1] = { m.win, m.wo or false } end return o")
    assert ms == [[K("Gina"), True], [K("Bert"), False]], ms
    # Dain comes back for the bronze match against Cora
    d.login()
    listen(d)
    w.tick(15)
    assert d.eval_py("local m = ns.EventLive:MyMatch(...); return m and { m.a, m.b, m.bronze or false }", occ) == \
        [K("Dain"), K("Cora"), True]
    for i in range(3):
        duel(w, by, "Gina", "Bert")
        duel(w, by, "Dain", "Cora")
        w.tick(5)
    w.tick(5)
    for c in cs:
        r = result(c, occ)
        assert r and r["champ"] == K("Gina") and r["second"] == K("Bert") and r["third"] == K("Dain"), (c.name, r)
    w.assert_no_errors()


@case
def a_derby_leader_who_leaves_loses_the_lead_and_an_angler_back_from_offline_fishes_on():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    occ = schedule(w, g, cs[1:], "fish", "shorten(120, 'Derby')")
    listen(*cs)
    start(w, g, occ)
    for c, n in ((b, 3), (co, 2), (d, 1)):
        for _ in range(n):
            catch(w, c)
    w.tick(3)
    assert got(d, "EVENT_TELL", occ) == ["Bert leads with 1 fish"], got(d, "EVENT_TELL", occ)
    # Bert leaves: off the board, the lead to Cora (told), his next catch counts for nothing
    assert b.eval("return (ns.Events:SignUp(..., false))", occ)
    w.tick(4)
    assert K("Bert") not in st(g, occ, "entrants")
    assert hst(g, occ, "scores.sc1") == {K("Cora"): 2, K("Dain"): 1}, hst(g, occ, "scores.sc1")
    assert got(d, "EVENT_TELL", occ)[-1] == "Cora leads with 2 fish", got(d, "EVENT_TELL", occ)
    catch(w, b)
    w.tick(2)
    assert hst(g, occ, "scores.sc1").get(K("Bert")) is None
    # Dain's game goes away and comes back: he fishes on (twice: he leads)
    d.logout()
    w.tick(10)
    d.login()
    listen(d)
    w.tick(20)
    catch(w, d)
    catch(w, d)
    w.tick(3)
    assert hst(g, occ, "scores.sc1") == {K("Cora"): 2, K("Dain"): 3}, hst(g, occ, "scores.sc1")
    assert got(d, "EVENT_TELL", occ)[-1] == "Dain leads with 3 fish", got(d, "EVENT_TELL", occ)
    w.run_until(lambda: st(g, occ, "phase") == "done", timeout=150, step=1)
    w.tick(5)
    r = result(co, occ)
    assert r["champ"] == K("Dain") and r["second"] == K("Cora") and r["scores"]["Fish"] == {K("Cora"): 2, K("Dain"): 3}, r
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Trouble: two events at once, sign-ups at the limit, an instance, clocks apart, a stop a moment late
# ------------------------------------------------------------------------------------------------------------------
@case
def two_events_at_once_keep_their_facts_and_messages_apart():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve"]
    w, by, cs = guild(names)
    g, b, co, d, e = cs
    for i, c in enumerate(cs):
        at(w, c, i * 3)
    # Gina's fishing derby (Gina, Cora, Dain) and Bert's hide and seek (Bert, Cora, Dain, Eve), at the same time
    derby = schedule(w, g, [co, d], "fish", "shorten(200, 'Derby')")
    hide = schedule(w, b, [co, d, e], "hide", "shorten(5, 'Hide'); shorten(200, 'Seek')")
    listen(*cs)
    start(w, g, derby)
    start(w, b, hide)
    w.tick(8)
    assert st(b, hide, "stage") == "s3"
    # each one's banners to its own entrants only
    for c in cs:
        assert ("Fish! 30 minutes: every fish counts." in got(c, "EVENT_SHOW", derby)) == (c in (g, co, d)), c.name
        assert ("Seek! 20 minutes." in got(c, "EVENT_SHOW", hide)) == (c in (b, co, d, e)), c.name
    # Cora's client senses for both: her fish go to the derby, Eve's (not in it) nowhere
    act = co.eval_py("local a = ns.EventSensors:_State(); local o = {} for k in pairs(a) do o[#o + 1] = k end table.sort(o) return o")
    assert act == sorted([derby, hide]), act
    catch(w, co)
    catch(w, e)
    w.tick(3)
    assert hst(g, derby, "scores.sc1") == {K("Cora"): 1}, hst(g, derby, "scores.sc1")
    # the seeker's clicks find hiders in the hide and seek only
    seeker = by[tags_of(b, hide, "tg2")[0]]
    hiders = [by[n] for n in tags_of(b, hide, "tg1")]
    for h in hiders:
        w.set_position(seeker, NAGRAND, 0.5, 0.5, subzone="Halaa")
        w.set_position(h, NAGRAND, 0.5 + 3 * YD, 0.5, subzone="Halaa")
        w.tick(3)
        seeker.eval("__MOCK.click_player(...)", h.name)
        w.tick(3)
    w.tick(5)
    assert st(b, hide, "phase") == "done" and st(g, derby, "phase") == "live"
    assert len(hst(g, derby, "tags") or {}) == 0, hst(g, derby, "tags")
    assert result(g, hide)["scores"]["Finds"] == {K(seeker.name): len(hiders)}
    assert result(g, derby) is None
    w.assert_no_errors()


@case
def sign_ups_at_the_limit():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve"]
    w, by, cs = guild(names)
    g, b, co, d, e = cs
    # the race with 3 spots (the host closes it): Gina, Bert, Cora fill them
    occ = schedule(w, g, [b, co], "race", "d.blocks.b1.set.spots = 3")
    assert d.eval_py("return { ns.Events:SignUp(...) }", occ, True) == [False, "It's full."]
    start(w, g, occ)
    assert sorted(short(k) for k in st(g, occ, "entrants")) == ["Bert", "Cora", "Gina"]
    w.tick(3)
    # while it runs, the run says: full (the host can't add him either)
    assert d.eval_py("return { ns.Events:SignUp(...) }", occ, True) == [False, "It's full."]
    assert g.eval_py("return { ns.EventLive:AddPlayer(...) }", occ, K("Dain")) == [False, "The sign-up is full."]
    # Cora leaves: a spot; Dain takes it
    assert co.eval("return (ns.Events:SignUp(..., false))", occ)
    w.tick(4)
    assert d.eval_py("return { ns.Events:SignUp(...) }", occ, True)[0] is True
    w.tick(4)
    assert sorted(short(k) for k in st(g, occ, "entrants")) == ["Bert", "Dain", "Gina"]
    assert me_api(d, occ)["point"][0] == "pc1"
    # closed: no more
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ)
    w.tick(4)
    assert e.eval_py("return { ns.Events:SignUp(...) }", occ, True) == [False, "Sign-up is closed."]
    w.assert_no_errors()


@case
def a_hider_in_an_instance():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g = cs[0]
    for i, c in enumerate(cs):
        at(w, c, i * 4)
    occ = schedule(w, g, cs[1:], "hide", "shorten(5, 'Hide'); shorten(600, 'Seek')")
    start(w, g, occ)
    w.tick(8)
    assert st(g, occ, "stage") == "s3"
    seeker = by[tags_of(g, occ, "tg2")[0]]
    hiders = [by[n] for n in tags_of(g, occ, "tg1")]
    at(w, seeker, 0, 0)
    for i, h in enumerate(hiders):
        at(w, h, 50 + i * 100, 0, "Spot %d" % (i + 1))
    w.tick(8)
    # the nearest hider goes into Mana-Tombs: out of the play area (told, pointed back; no yards there), and where
    # they were before isn't where they are: the Hint names the next one
    near = hiders[0]
    w.enter_instance("Mana-Tombs", 557, "party", 5, clients=[near])
    w.tick(5)
    m = me_api(near, occ)
    assert m["feed"][0] == "Go back to the play area" and m["point"] == ["pc1"], m
    pos = hrun(g, occ, "local p = st.pos[select(2, ...)]; return p and { map = p.map or false, wx = p.wx or false }", K(near.name))
    assert pos == {"map": False, "wx": False}, pos
    w.tick(2)
    assert seeker.eval("return ns.EventLive:Press(..., 'Hint')", occ)
    w.tick(3)
    assert me_api(seeker, occ)["feed"][0] == "Nearest hider: Spot 2", me_api(seeker, occ)["feed"]
    # back out: in the play area, where they are known again
    w.leave_instance(clients=[near])
    at(w, near, 50, 0, "Spot 1")
    w.tick(8)
    assert me_api(near, occ)["point"] == [] and hrun(g, occ, "return st.pos[select(2, ...)].map", K(near.name)) == NAGRAND
    w.assert_no_errors()


def skew(c, sec):
    """c's server clock runs `sec` seconds off the others' (GetServerTime and C_DateAndTime as the client has them)."""
    c._set_time = lambda: c.M.set_time(c.time_offset + c.world.now, c.world.server_time + sec)
    c._step = lambda dt: c.M.step(c.time_offset + c.world.now, c.world.server_time + sec, dt)


@case
def duels_reported_by_clocks_apart_count_once():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, by, cs = guild(names)
    g, b, co, d = cs
    skew(b, 5)
    skew(d, -4)
    assert b.eval("return GetServerTime()") - g.eval("return GetServerTime()") == 5
    occ = schedule(w, g, cs[1:], "duel", "d.blocks.b2.set.seed = 'order'")
    listen(*cs)
    start(w, g, occ)
    # (sign-up order is by each one's clock: Dain's runs behind, he signed up "first")
    semis = [(short(a), short(bb)) for _, a, bb, _, _, _ in playing(g, occ)]
    assert len(semis) == 2, semis
    # the semi-finals, 2-0 to the first named (each duel reported by two clocks up to 9 s apart)
    for _ in range(2):
        for a, bb in semis:
            duel(w, by, a, bb)
        w.tick(12)
    ms = hrun(g, occ, "local o = {} local bk = run:MainBracket() for _, mid in ipairs(bk.rounds[1]) do local m = bk.m[mid] "
                      "o[#o + 1] = { m.win, m.wa, m.wb } end return o")
    assert ms == [[K(semis[0][0]), 2, 0], [K(semis[1][0]), 2, 0]], ms
    # no question who won (every duel agreed)
    assert not st(g, occ, "asks"), st(g, occ, "asks")
    # the banners reach the clients whose clocks are off too (within their 20 s)
    final = "Final: %s vs %s" % (semis[0][0], semis[1][0])
    for c in cs:
        assert got(c, "EVENT_SHOW", occ) == [final], (c.name, got(c, "EVENT_SHOW", occ))
    w.assert_no_errors()


@case
def red_light_a_stop_a_moment_late_is_safe():
    names = ["Gina", "Bert", "Cora"]
    w, by, cs = guild(names)
    g, b, co = cs
    for i, c in enumerate(cs):
        w.set_position(c, NAGRAND, START_LINE[0] + i * 2 * YD, START_LINE[1], subzone="Halaa")
    occ = schedule(w, g, cs[1:], "redlight", "shorten(300, 'Game')")
    start(w, g, occ)
    assert g.eval("return ns.EventLive:CloseSignup(...)", occ)
    w.tick(2)
    for c in cs:
        move(c, True)
    w.run_until(lambda: light(g, occ) == "turning", timeout=20, step=0.1)
    # Bert sees the banner and stops a second and a bit later (human, and the banner's way to him); Cora at once;
    # Gina doesn't stop
    move(co, False)
    w.tick(1.2)
    move(b, False)
    w.run_until(lambda: light(g, occ) == "red", timeout=5, step=0.1)
    w.tick(1)
    assert tags_of(g, occ, "tg2") == ["Gina"], tags_of(g, occ, "tg2")
    w.assert_no_errors()


@case
def demo_mode_mid_event_sends_nothing_and_practice_plays_an_example_to_the_end():
    names = ["Gina", "Bert", "Cora"]
    w, by, cs = guild(names)
    g, b, co = cs
    occ = schedule(w, g, cs[1:], "quiz", "waits(1); asktime('ak1', 20)")
    # the host can't start it in demo mode
    g.eval("ns.Demo:SetEnabled(true)")
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is False
    g.eval("ns.Demo:SetEnabled(false)")
    start(w, g, occ)
    wait_question(w, b, occ, QUIZ[0][0])
    # Cora turns demo mode on: her answer goes nowhere, nothing leaves her client
    co.eval("ns.Demo:SetEnabled(true)")
    a0 = len(w.addon_log)
    assert answer(co, occ, "ak1", QUIZ[0][1]) is False
    w.tick(3)
    assert not [e for e in w.addon_log[a0:] if e["sender"] == K("Cora")], w.addon_log[a0:]
    # off again: she answers the question still open
    co.eval("ns.Demo:SetEnabled(false)")
    w.tick(2)
    assert answer(co, occ, "ak1", QUIZ[0][1]) is True
    w.tick(3)
    assert hst(g, occ, "scores.sc1") == {K("Cora"): 1}, hst(g, occ, "scores.sc1")
    g.eval("ns.EventLive:EndEvent(...)", occ)
    w.tick(3)
    # practice: the transmog contest to its end, the dummies judging and voting by themselves; nothing goes out
    n0, a1 = len(w.chat_log), len(w.addon_log)
    out = g.eval_py("""local L = ns.EventLive
        local run = L:StartPractice(ns.EventBlocks:Example('tmog'), 5)
        local logs = {}
        ns:On('EVENT_PRACTICE_LOG', function(kind, text) if kind == 'guild' then logs[#logs + 1] = text end end)
        T_run = run
        T_logs = logs
        return run.st.stage""")
    assert out == "s2"
    # (the host is asked who judges: in practice that's me, through the practice's own input; never the live one)
    w.tick(2)
    assert g.eval("return ns.EventLive:AnswerAsk2('practice', 'ak1', { 'Dummy1-Practice' })") is False
    g.eval("ns.EventLive:PracticeAnswer('Gina-Thunderstrike', 'ak1', { 'Dummy1-Practice', 'Dummy2-Practice' })")
    for _ in range(40):
        if g.eval("return T_run.st.phase") != "live":
            break
        g.eval("ns.EventLive:PracticeSkip()")
        w.tick(7)
    r = g.eval_py("""local o = { phase = T_run.st.phase, stage = T_run.st.stage, logs = T_logs, errs = {} }
        for _, l in ipairs(T_run.log) do if l.kind == 'error' then o.errs[#o.errs + 1] = l.text end end
        o.judges = #T_run:Tagged('tg1')
        return o""")
    assert r["phase"] == "done" and r["stage"] == "s5" and r["errs"] == [] and r["judges"] == 2, r
    assert len(r["logs"]) == 1 and r["logs"][0].endswith(" wins the transmog contest!"), r["logs"]
    assert len(w.chat_log) == n0 and not [e for e in w.addon_log[a1:] if "practice" in str(e)], w.chat_log[n0:]
    g.eval("ns.EventLive:StopPractice()")
    w.assert_no_errors()


@case
def a_big_trivia_night_tells_everyone_in_time():
    # 14 players, everyone right at once: 14 "Right!" lines a question on the host's message prefix (the server lets
    # about 10 through at once, then 1 a second)
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Finn", "Hana", "Ivo", "Jon", "Kai", "Lea", "Max", "Noa", "Oli"]
    w, by, cs = guild(names)
    g = cs[0]
    occ = schedule(w, g, cs[1:], "quiz", "waits(1); asktime('ak1', 20)")
    listen(*cs)
    start(w, g, occ)
    late = []
    for i, (q, a) in enumerate(QUIZ):
        wait_question(w, cs[1], occ, q)
        t0 = w.now
        for c in cs:
            assert answer(c, occ, "ak1", a) is True
        w.run_until(lambda: all(got(c, "EVENT_TELL", occ).count("Right!") >= i + 1 for c in cs), timeout=60, step=0.5)
        late.append(w.now - t0)
    assert max(late) <= 5, late
    # (the message prefix was never throttled by the server)
    assert not [x for x in g.warnings if "throttled" in x and "CDLf" in x], [x for x in g.warnings if "throttled" in x]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
