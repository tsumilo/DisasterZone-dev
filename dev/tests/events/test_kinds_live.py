"""Events part 2, live (Core/EventSensors.lua, Core/EventLive.lua, Core/Events.lua): what an entrant's game sees, the
facts it tells the host, the host's messages (EVM) and guild posts, trust, the me-API, practice, nameplates, and the
data layer (definitions in CleanDef, Migrate on load / receive / demo, results with scores and tags, sync caps).

Covers: every sensor from the mock's game events and APIs (kills, loot, fish, deaths, mounting, moving, places in
world yards, clicks / points / emotes up close, radar, positions, World flags / items / gold / zone); facts reaching
the host's run; EVM reaching only the players named; the guild post's rate; a non-entrant's facts and facts for senses
the def doesn't use ignored; nothing sent in demo mode or practice; friendly nameplates put back; a hide and seek and a
fishing derby across four clients end to end.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_live.py [-k name]   (from dev)"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
NAGRAND = 1951
YD = 1.0 / 5525.0       # one yard east-west on the mock's Nagrand map (a map 5525 yards wide)
YDY = 1.0 / 3683.33     # one yard north-south


def K(n):
    return n + "-Thunderstrike"


def guild(names, tick=HELLO, **kw):
    w = World(**kw)
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


BUILD = r"""
local B = ns.EventBlocks
local N, C, J, If, T, V = B.Build.N, B.Build.C, B.Build.J, B.Build.If, B.Build.T, B.Build.V
local function S(id, top) d.scripts[#d.scripts + 1] = { id = id, st = '*', x = 0, y = 0, top = top } end
"""


def arrive(w, players, occ):
    """Ticks until every player has the calendar event (a big def takes a few parts a second to arrive)."""
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in players), timeout=90, step=0.5)


def event(w, host, players, body, start=True, name="Test event"):
    """The host saves a def (blank: no Sign-up, so the entrants are who signed up; `body` is Lua filling `d`, with
    N / C / J / If / T / V / S(id, top) at hand), schedules it, the players sign up, it starts. Returns occId."""
    occ = host.eval("local d = ns.Events:NewDef(false)\nd.name = %r\n" % name + BUILD + body + """
        local probs = ns.EventBlocks:Problems(d)
        assert(#probs == 0, 'problems: ' .. tostring(probs[1] and probs[1].text))
        assert(ns.Events:SaveDef(d), 'save')
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    assert occ, "schedule"
    w.tick(3)
    arrive(w, players, occ)
    for c in players:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ), c.name
    w.tick(3)
    if start:
        ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
        assert ok[0] is True, ok
        w.tick(3)
    return occ


def example(w, host, players, key, setup=""):
    """The host saves one of B:Examples (setup: Lua on `d` first: shorter timers, places), schedules it and the
    players sign up; it isn't started. Returns occId."""
    occ = host.eval("local d = ns.EventBlocks:Example(...)\nassert(d, 'no example')\nd.id = nil\nd.by = nil\n" + BUILD
                    + setup + """
        local probs = ns.EventBlocks:Problems(d)
        assert(#probs == 0, 'problems: ' .. tostring(probs[1] and probs[1].text))
        assert(ns.Events:SaveDef(d), 'save')
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""", key)
    assert occ, "schedule"
    w.tick(3)
    arrive(w, players, occ)
    for c in players:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ), c.name
    w.tick(3)
    return occ


# Timers of a def's scripts set to `n` seconds (examples run for minutes)
SHORT_TIMERS = r"""
local function shorten(sec, name)   -- (name: only that timer)
  for _, s in ipairs(d.scripts) do
    B:Walk(s.top, function(p) if p.k == 'tm.start' and (not name or p.a[2] == name) then p.a[1] = sec end end)
  end
end
"""

SPY = r"""
local occ = ...
local h = ns.EventLive:_State()[occ]
T_facts = {}
for _, fn in ipairs({ 'Happen', 'Place', 'Touch', 'Radar', 'Pos', 'AskAnswer', 'Press' }) do
  local orig = h.run[fn]
  h.run[fn] = function(self, ...)
    T_facts[#T_facts + 1] = { fn, ... }
    return orig(self, ...)
  end
end
"""


def spy(host, occ):
    """Records every run input on the host's run (T_facts: { {fn, args...} })."""
    host.eval(SPY, occ)


def facts(host, fn=None):
    out = host.eval_py("return T_facts") or []
    return [f for f in out if fn is None or f[0] == fn]


def run_st(host, occ, path):
    """A part of the host's run state (host only parts too): run.st.<path>."""
    return host.eval_py("local h = ns.EventLive:_State()[...]; return h and h.run.st." + path, occ)


def score(host, occ, sid, who):
    return host.eval_py("local st = ns.EventLive:GetState(...); local t = st.scores[select(2, ...)]; "
                        "return t and t[select(3, ...)]", occ, sid, K(who))


def moments(c, occ):
    return c.eval_py("local out = {}; for _, m in ipairs(ns.EventLive:GetState(...).moments or {}) do "
                     "out[#out + 1] = m.text end; return out", occ) or []


def event_msgs(w, since, sender=None):
    return [e for e in w.addon_log[since:] if e["prefix"] in ("CDLe", "CDLf") and (sender is None or e["sender"] == K(sender))]


def cleu_kill(c, creature="Hogger", src=None, dst="Creature-0-1-2-3-448-000001"):
    c.eval("__MOCK.combat_log(GetServerTime(), 'PARTY_KILL', false, %s, 'x', 0, 0, %r, %r, 0, 0)" % (
        src or "UnitGUID('player')", dst, creature))


def loot_line(c, item_id, name, count=1):
    link = "|cffffffff|Hitem:%d::::::::70:::::|h[%s]|h|r" % (item_id, name)
    text = ("You receive loot: %sx%d." % (link, count)) if count > 1 else ("You receive loot: %s." % link)
    c.fire("CHAT_MSG_LOOT", text, c.full_name, "", "", c.name, "", 0, 0, "", 0, 0, c.guid, 0, False, False, False,
           False)


LISTEN = r"""
T_got = {}
for _, m in ipairs({ 'EVENT_SHOW', 'EVENT_TELL', 'EVENT_SOUND' }) do
  ns:On(m, function(occ, text) T_got[#T_got + 1] = { m, occ, text } end)
end
"""


def listen(*cs):
    for c in cs:
        c.eval(LISTEN)


def got(c):
    return [tuple(x) for x in (c.eval_py("return T_got") or [])]


def raw_fact(c, occ, fields, host="Gina", dist="WHISPER"):
    """c sends an EVF of its own making (a changed addon), bypassing its sensors and rate."""
    c.eval("local occ, host, dist = ...\nlocal msg = " + fields + "\nmsg.t, msg.o, msg.at = 'EVF', occ, GetServerTime()\n"
           "ns.Comm:Send(msg, dist, dist == 'WHISPER' and host or nil, 'event')", occ, K(host), dist)


# ------------------------------------------------------------------------------------------------------------------
# Sensors: only what the def uses, only for entrants
# ------------------------------------------------------------------------------------------------------------------
@case
def sensors_watch_only_what_the_def_uses_and_only_for_entrants():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    occ = event(w, g, [b], """
        d.scores = { sc1 = { n = 'Kills', high = true, fmt = 'num', board = true } }
        S('k1', B:Stack(N('ev.happen', 'kill'), N('pt.add', 1, 'sc1', C('player'))))""")
    w.tick(2)
    want = b.eval_py("local a, want = ns.EventSensors:_State(); local n = 0; for _ in pairs(a) do n = n + 1 end; "
                     "return { n = n, kill = want.happen.kill or false, target = want.target, emote = want.emote, "
                     "state = want.state, poll = want.poll or false }")
    assert want == {"n": 1, "kill": True, "target": False, "emote": False, "state": False, "poll": False}, want
    # only the combat log is watched for it (no target, emote or loot events)
    assert b.eval_py("local a, want = ns.EventSensors:_State(); return want.happen") == {"kill": True}
    # Cora isn't in it: she watches nothing, and her kills go nowhere
    assert c.eval("local a = ns.EventSensors:_State(); return next(a) == nil")
    a0 = len(w.addon_log)
    cleu_kill(c)
    w.tick(1)
    assert not event_msgs(w, a0, "Cora")
    # Bert's kill reaches the host's run; a kill by someone else in his combat log, or of a player, doesn't count
    spy(g, occ)
    cleu_kill(b, "Hogger")
    cleu_kill(b, "Bandit", src="'Player-0-00000099'")
    cleu_kill(b, "Cora", dst="Player-0-00000003")
    w.tick(2)
    hs = facts(g, "Happen")
    assert len(hs) == 1 and hs[0][1] == K("Bert") and hs[0][2] == "kill" and hs[0][3]["creature"] == "Hogger", hs
    assert score(g, occ, "sc1", "Bert") == 1
    # the event ends: nothing is watched any more
    g.eval("ns.EventLive:EndEvent(...)", occ)
    w.tick(3)
    assert b.eval("local a, want = ns.EventSensors:_State(); return next(a) == nil and not want.happen.kill")
    w.assert_no_errors()


@case
def loot_fish_and_deaths_reach_the_host():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    occ = event(w, g, [b], """
        d.scores = { sc1 = { n = 'Fish', high = true, fmt = 'num', board = true },
                     sc2 = { n = 'Ore', high = true, fmt = 'num', board = true },
                     sc3 = { n = 'Deaths', high = true, fmt = 'num', board = false } }
        S('f1', B:Stack(N('ev.happen', 'fish'), N('pt.add', 1, 'sc1', C('player'))))
        S('f2', B:Stack(N('ev.happen', 'loot', 'Fel Iron Ore'), N('pt.add', C('count'), 'sc2', C('player'))))
        S('f3', B:Stack(N('ev.happen', 'die'), N('pt.add', 1, 'sc3', C('player'))))""")
    spy(g, occ)
    # ore from a vein (not fishing): loot only
    loot_line(b, 23424, "Fel Iron Ore", 3)
    w.tick(1)
    # a fishing window (the mock: LOOT_OPENED with IsFishingLoot, the lines, LOOT_CLOSED)
    b.eval("__MOCK.fish_loot({ { 27422, 1 } })")
    w.tick(1)
    # with autoloot the lines come after the window closed: a moment later they're still the catch
    b.eval("__MOCK.fishing_loot = true")
    b.fire("LOOT_OPENED", True, False)
    b.eval("__MOCK.fishing_loot = false")
    b.fire("LOOT_CLOSED")
    loot_line(b, 27425, "Spotted Feltail", 2)
    # long after: an item, not a fish
    w.tick(5)
    loot_line(b, 27422, "Barbed Gill Trout")
    b.fire("PLAYER_DEAD")
    w.tick(3)
    hs = [(f[2], f[3].get("item"), f[3].get("count")) for f in facts(g, "Happen")]
    assert [x for x in hs if x[0] == "fish"] == [("fish", 27422, 1), ("fish", 27425, 2)], hs
    assert [x for x in hs if x[0] == "loot"] == [("loot", 23424, 3), ("loot", 27422, 1), ("loot", 27425, 2),
                                                 ("loot", 27422, 1)], hs
    assert ("die", None, None) in hs, hs
    assert score(g, occ, "sc1", "Bert") == 2, score(g, occ, "sc1", "Bert")
    assert score(g, occ, "sc2", "Bert") == 3, score(g, occ, "sc2", "Bert")
    assert score(g, occ, "sc3", "Bert") == 1
    w.assert_no_errors()


@case
def mounting_and_moving_are_noticed_when_used():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    occ = event(w, g, [b], """
        S('m1', B:Stack(N('ev.happen', 'mount'), N('ch.moment', J(C('player'), ' mounts'))))
        S('m2', B:Stack(N('ev.happen', 'dismount'), N('ch.moment', J(C('player'), ' dismounts'))))
        S('m3', B:Stack(N('ev.happen', 'move'), N('ch.moment', J(C('player'), ' moves'))))
        S('m4', B:Stack(N('ev.happen', 'stop'), N('ch.moment', J(C('player'), ' stops'))))""")
    spy(g, occ)
    w.tick(1)
    b.eval("__MOCK.mounted = true")
    w.tick(1)
    b.eval("__MOCK.speed = 7")
    w.tick(1)
    b.eval("__MOCK.speed = 0")
    w.tick(1)
    b.eval("__MOCK.mounted = false")
    w.tick(2)
    whats = [f[2] for f in facts(g, "Happen")]
    assert whats == ["mount", "move", "stop", "dismount"], whats
    ms = moments(g, occ)
    assert "Bert mounts" in ms and "Bert stops" in ms and "Bert dismounts" in ms, ms
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Places and positions
# ------------------------------------------------------------------------------------------------------------------
@case
def places_in_and_out_by_world_yards_and_off_in_instances():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    w.set_position(b, NAGRAND, 0.5, 0.5)   # in the Ring as it starts
    occ = event(w, g, [b], """
        d.places = { pc1 = { n = 'Ring', map = 1951, x = 0.5, y = 0.5, r = 30 },
                     pc2 = { n = 'Halaa', map = 1951, x = 0.6, y = 0.5, r = 30 },
                     pc3 = { n = 'Garadar', sz = 'Garadar' } }
        S('p1', B:Stack(N('pc.enter'), N('ch.moment', J(C('player'), ' in ', C('place')))))
        S('p2', B:Stack(N('pc.leave', 'pc1'), N('ch.moment', J(C('player'), ' left the ring'))))""")
    w.tick(2)
    assert run_st(g, occ, "inplace") == {"pc1": {K("Bert"): True}}, run_st(g, occ, "inplace")
    spy(g, occ)
    # 25 yards east, then 31 (in: the edge has 2 yards of slack once in), then 33: out
    for yards in (25, 31):
        w.set_position(b, NAGRAND, 0.5 + yards * YD, 0.5)
        w.tick(1)
    assert facts(g, "Place") == [], facts(g, "Place")
    w.set_position(b, NAGRAND, 0.5 + 33 * YD, 0.5)
    w.tick(1)
    assert [f[1:] for f in facts(g, "Place")] == [[K("Bert"), "pc1", False]], facts(g, "Place")
    # into Halaa, and a subzone place by its name
    w.set_position(b, NAGRAND, 0.6 + 10 * YD, 0.5, subzone="Garadar")
    w.tick(1)
    places = [f[1:] for f in facts(g, "Place")]
    assert [K("Bert"), "pc2", True] in places and [K("Bert"), "pc3", True] in places, places
    assert "Bert left the ring" in moments(g, occ), moments(g, occ)
    # into an instance: out of every place, then nothing
    w.enter_instance("Mana-Tombs", 557, "party", 5, clients=[b])
    w.tick(2)
    places = [f[1:] for f in facts(g, "Place")]
    assert [K("Bert"), "pc2", False] in places and [K("Bert"), "pc3", False] in places, places
    n = len(places)
    w.tick(5)
    assert len(facts(g, "Place")) == n
    w.assert_no_errors()


@case
def positions_go_to_the_host_only_while_distances_are_used_and_never_leave_it():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    w.set_position(b, NAGRAND, 0.5, 0.5, subzone="Halaa")
    occ = event(w, g, [b], """
        d.places = { pc1 = { n = 'Ring', map = 1951, x = 0.5, y = 0.5 - 100 / 3683.33, r = 20 } }
        S('y0', B:Stack(N('ev.start'), N('as.give', N('pl.all'), 'Where')))
        S('y1', B:Stack(N('as.press', 'Where'),
            N('ch.tell', C('player'), J('Yards: ', N('pc.yards', C('player'), 'pc1'), ' in ', N('pc.sub', C('player'))))))""")
    w.tick(2)
    pos = run_st(g, occ, "pos")
    assert pos and pos.get(K("Bert")) and pos[K("Bert")]["map"] == NAGRAND and pos[K("Bert")]["sz"] == "Halaa", pos
    # standing still: no more for a while (30 s at most); 25 yards: at once
    a0 = len(w.addon_log)
    w.tick(20)
    assert len(event_msgs(w, a0, "Bert")) == 0, event_msgs(w, a0, "Bert")
    w.set_position(b, NAGRAND, 0.5 + 25 * YD, 0.5)
    w.tick(1)
    assert len(event_msgs(w, a0, "Bert")) == 1
    assert abs(run_st(g, occ, "pos")[K("Bert")]["x"] - (0.5 + 25 * YD)) < 0.0002
    # the button: yards from Bert to the Ring (about 103), in his tracker feed
    listen(b)
    assert b.eval("return ns.EventLive:Press(..., 'Where')", occ)
    w.tick(2)
    feed = b.eval_py("return ns.EventLive:MyFeed(...)", occ)
    assert feed and feed[0]["text"].startswith("Yards: 10") and feed[0]["text"].endswith(" in Halaa"), feed
    assert ("EVENT_TELL", occ, feed[0]["text"]) in got(b)
    # never on the wire: not in the states Cora (watching) has
    assert c.eval("return ns.EventLive:GetState(...).pos == nil", occ)
    assert c.eval("return ns.EventLive:GetState(...).inplace == nil", occ)
    # (the host keeps all of it for its own /reload)
    g.fire("PLAYER_LOGOUT")
    assert g.eval("local e = ns.db.eventHosting[...]; return e.st.pos['Bert-Thunderstrike'] ~= nil", occ)
    # Cora's def has no distances for a second event: her client sends no positions for that one
    occ2 = event(w, g, [c], "S('n1', B:Stack(N('ev.happen', 'die'), N('ch.moment', 'x')))")
    w.set_position(c, NAGRAND, 0.3, 0.3)
    a1 = len(w.addon_log)
    w.tick(10)
    sent = [e for e in event_msgs(w, a1, "Cora")]
    assert not sent, sent
    assert occ2
    w.assert_no_errors()


@case
def world_flags_items_gold_and_zone_reach_the_host():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    w.set_position(b, NAGRAND, 0.4, 0.4, subzone="Sunspring Post")
    b.eval("__MOCK.money = 1000")
    occ = event(w, g, [b], """
        d.vars = { { n = 'Flying', t = 'num' } }
        S('w1', B:Stack(N('ev.every', 10),
            If(N('wo.is', N('pl.host'), 'flying'), N('ch.moment', 'host flies')),
            If(N('lo.gt', N('wo.items', 23424, N('pl.host')), 0), N('ch.moment', 'ore')),
            If(N('lo.gt', N('wo.gold', N('pl.host')), 0), N('ch.moment', 'gold')),
            N('ch.moment', J('sub ', N('pc.sub', N('pl.host'))))))""")
    w.tick(2)
    # (flags: flying, swimming, in combat, mounted, moving, dead; items and gold only as they change)
    b.eval("__MOCK.flying = true")
    w.tick(1.5)
    b.eval("__MOCK.give_item(23424, 3); __MOCK.money = 1500")
    w.set_position(b, NAGRAND, 0.41, 0.4, subzone="Halaa")
    w.tick(3)
    fl = run_st(g, occ, "flags")[K("Bert")]
    assert fl["flying"] is True and fl["swimming"] is False and fl["combat"] is False, fl
    pos = run_st(g, occ, "pos")[K("Bert")]
    assert pos["items"] == {"23424": 3} and pos["gold"] == 500 and pos["sz"] == "Halaa", pos
    # no position for it: the def has no distances
    assert pos.get("map") is None, pos
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Touches, points, emotes, radar
# ------------------------------------------------------------------------------------------------------------------
@case
def a_click_up_close_touches_and_a_macro_is_radar():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b, c, d = cs
    for x, dx in ((g, 50), (b, 0), (c, 3), (d, 200)):
        w.set_position(x, NAGRAND, 0.5 + dx * YD, 0.5)
    occ = event(w, g, [b, c, d], """
        S('t1', B:Stack(N('pl.touch', nil, nil, 'click'), N('ch.moment', J(C('toucher'), ' found ', C('touched')))))
        S('t2', B:Stack(N('pl.touch', nil, nil, 'point'), N('ch.moment', J(C('toucher'), ' pointed at ', C('touched')))))
        S('t3', B:Stack(N('pl.touch', nil, nil, 'emote', 'HUG'), N('ch.moment', J(C('toucher'), ' hugged ', C('touched')))))
        S('t4', B:Stack(N('pl.radar'), N('ch.moment', J(C('who'), ' peeked at ', C('whom')))))""")
    spy(g, occ)
    # a click on Cora, 3 yards away: found
    b.eval("__MOCK.click_player('Cora')")
    w.tick(1)
    assert [f[1:] for f in facts(g, "Touch")] == [[K("Bert"), K("Cora"), "click"]], facts(g, "Touch")
    # a click on Dain, 200 yards away: not up close, nothing
    b.eval("__MOCK.click_player('Dain')")
    w.tick(1)
    assert len(facts(g, "Touch")) == 1
    # a /target macro, and a click on Cora's raid frame (the mouse over a unit frame): radar, not a touch
    b.eval("__MOCK.target_player('Dain')")
    w.tick(1)
    b.eval("local f = CreateFrame('Button', 'T_RaidFrame2', UIParent); f:SetAttribute('unit', 'raid2'); "
           "__MOCK.click_player('Cora', f)")
    w.tick(1)
    assert [f[1:] for f in facts(g, "Radar")] == [[K("Bert"), K("Dain")], [K("Bert"), K("Cora")]], facts(g, "Radar")
    assert len(facts(g, "Touch")) == 1
    # /point at my target (the DoEmote hook names it), 3 yards away
    w.tick(3)
    b.eval("__MOCK.target_player('Cora'); DoEmote('POINT', '')")
    w.tick(1)
    assert [K("Bert"), K("Cora"), "point", None] in [f[1:] + [None] * (4 - len(f[1:])) for f in facts(g, "Touch")], \
        facts(g, "Touch")
    # without the hook, English: "You point at Cora."
    w.tick(3)
    b.fire("CHAT_MSG_TEXT_EMOTE", "You point at Cora.", b.full_name)
    w.tick(1)
    assert len([f for f in facts(g, "Touch") if f[3] == "point"]) == 2, facts(g, "Touch")
    # a hug up close is an emote touch with its token (the name as typed)
    b.eval("DoEmote('HUG', 'cora')")
    w.tick(1)
    hugs = [f for f in facts(g, "Touch") if f[3] == "emote" and f[4] == "HUG"]
    assert len(hugs) == 1 and hugs[0][1:] == [K("Bert"), K("Cora"), "emote", "HUG"], hugs
    # (a /point is an emote touch too, for a def that asks for "{POINT} up close")
    assert [f for f in facts(g, "Touch") if f[3] == "emote" and f[4] == "POINT"], facts(g, "Touch")
    ms = moments(g, occ)
    for m in ("Bert found Cora", "Bert pointed at Cora", "Bert hugged Cora", "Bert peeked at Dain"):
        assert m in ms, (m, ms)
    # a click on the one I target already (the target doesn't change, only the mouse goes down): still a find
    w.tick(3)
    b.eval("__MOCK.target_player('Cora')")
    w.tick(1)
    n = len([f for f in facts(g, "Touch") if f[3] == "click"])
    b.eval("__MOCK.click_player('Cora')")
    w.tick(1)
    assert len([f for f in facts(g, "Touch") if f[3] == "click"]) == n + 1, facts(g, "Touch")
    # someone not in the event: nothing at all
    e = Client(w, "Eve", guild_rank=3)
    e.load_addon()
    w.tick(5)
    a0 = len(w.addon_log)
    b.eval("__MOCK.click_player('Eve')")
    w.tick(2)
    assert not event_msgs(w, a0, "Bert")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The host's messages (EVM) and guild posts
# ------------------------------------------------------------------------------------------------------------------
@case
def messages_reach_only_the_players_named():
    names = ["Gina", "Bert", "Cora", "Dain", "Eve", "Finn", "Watcher"]
    w, cs = guild(names)
    by = {c.name: c for c in cs}
    g = by["Gina"]
    occ = event(w, g, [by[n] for n in names[1:6]], "S('x1', B:Stack(N('ev.happen', 'die'), N('ch.moment', 'x')))")
    listen(*cs)
    out = "local h = ns.EventLive:_State()[select(1, ...)]; local o = h.run.out; "
    a0 = len(w.addon_log)
    # two players: a whisper each; me too (straight to my screen)
    g.eval(out + "o.show({ 'Bert-Thunderstrike', 'Cora-Thunderstrike', 'Gina-Thunderstrike' }, 'Two and me')", occ)
    w.tick(2)
    evm = [e for e in event_msgs(w, a0, "Gina") if e["chat_type"] == "WHISPER"]
    assert sorted(e["target"] for e in evm) == ["Bert", "Cora"], evm
    for n in names:
        has = ("EVENT_SHOW", occ, "Two and me") in got(by[n])
        assert has == (n in ("Gina", "Bert", "Cora")), (n, got(by[n]))
    # every entrant: one GUILD message for all of them (the watcher isn't one)
    a1 = len(w.addon_log)
    g.eval(out + "o.tell(h.run.st.entrants, 'Everyone')", occ)
    w.tick(2)
    sent = event_msgs(w, a1, "Gina")
    assert len(sent) == 1 and sent[0]["chat_type"] == "GUILD", sent
    # (on a budget of their own: a banner never waits behind a big state of the run)
    assert sent[0]["prefix"] == "CDLf", sent[0]["prefix"]
    for n in names:
        assert (("EVENT_TELL", occ, "Everyone") in got(by[n])) == (n != "Watcher"), (n, got(by[n]))
    assert by["Eve"].eval_py("return ns.EventLive:MyFeed(...)[1].text", occ) == "Everyone"
    # four of five: one GUILD message naming them
    a2 = len(w.addon_log)
    g.eval(out + "o.show({ 'Bert-Thunderstrike', 'Cora-Thunderstrike', 'Dain-Thunderstrike', 'Eve-Thunderstrike' }, 'Four')", occ)
    w.tick(2)
    sent = event_msgs(w, a2, "Gina")
    assert len(sent) == 1 and sent[0]["chat_type"] == "GUILD", sent
    for n in names:
        assert (("EVENT_SHOW", occ, "Four") in got(by[n])) == (n in ("Bert", "Cora", "Dain", "Eve")), n
    # a sound: played, then told to the UI
    by["Finn"].eval("wipe(__MOCK.sounds)")
    g.eval(out + "o.sound({ 'Finn-Thunderstrike' }, 'warning')", occ)
    w.tick(2)
    assert ("EVENT_SOUND", occ, "warning") in got(by["Finn"])
    assert len(by["Finn"].sounds) == 1, by["Finn"].sounds
    # the text is cleaned: no escape codes
    g.eval(out + "o.show({ 'Bert-Thunderstrike' }, '|cffff0000Red|r text')", occ)
    w.tick(2)
    assert ("EVENT_SHOW", occ, "cffff0000Redr text") in got(by["Bert"]), got(by["Bert"])
    # an entrant (not the host) can't send one: nobody shows it
    by["Cora"].eval("ns.Comm:Send({ t = 'EVM', o = ..., to = 'all', k = 'show', text = 'Forged', at = GetServerTime() }, "
                    "'GUILD', nil, 'event')", occ)
    # nor a whisper of one, nor the host's own one from long ago
    by["Cora"].eval("ns.Comm:Send({ t = 'EVM', o = ..., k = 'show', text = 'Forged 2', at = GetServerTime() }, "
                    "'WHISPER', 'Bert-Thunderstrike', 'event')", occ)
    g.eval("ns.Comm:Send({ t = 'EVM', o = ..., k = 'show', text = 'Old', at = GetServerTime() - 60 }, "
           "'WHISPER', 'Bert-Thunderstrike', 'event')", occ)
    w.tick(2)
    for n in names:
        texts = [x[2] for x in got(by[n])]
        assert "Forged" not in texts and "Forged 2" not in texts and "Old" not in texts, (n, texts)
    # many whispers: at most 4 a second, the rest wait their turn
    a3 = len(w.addon_log)
    g.eval(out + "for i = 1, 3 do for _, k in ipairs({ 'Bert-Thunderstrike', 'Cora-Thunderstrike', "
           "'Dain-Thunderstrike', 'Eve-Thunderstrike' }) do o.tell({ k }, 'Line ' .. i) end end", occ)
    w.tick(0.5)
    first = len(event_msgs(w, a3, "Gina"))
    w.tick(4)
    assert first == 4 and len(event_msgs(w, a3, "Gina")) == 12, (first, len(event_msgs(w, a3, "Gina")))
    w.assert_no_errors()


@case
def the_guild_post_once_every_10_s_and_20_an_event():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    occ = event(w, g, [b], "S('x1', B:Stack(N('ev.happen', 'die'), N('ch.moment', 'x')))")
    out = "local h = ns.EventLive:_State()[select(1, ...)]; local o = h.run.out; "
    n0 = len(w.chat_log)

    def posts():
        return [e["text"] for e in w.chat_log[n0:] if e["chat_type"] == "GUILD"]
    # five at once: the first now, then one every 10 s; past three waiting, the oldest waiting one goes
    g.eval(out + "for i = 1, 5 do o.guild('Post ' .. i) end", occ)
    w.tick(1)
    assert posts() == ["Post 1"], posts()
    w.tick(10)
    assert posts() == ["Post 1", "Post 3"], posts()
    w.tick(25)
    assert posts() == ["Post 1", "Post 3", "Post 4", "Post 5"], posts()
    # escape codes and line breaks don't reach the chat
    w.tick(10)
    g.eval(out + "o.guild('|cffff0000GG|r\\nall')", occ)
    w.tick(1)
    assert posts()[-1] == "cffff0000GGr all", posts()
    # 20 an event: the count travels in the state (a host who takes over goes on counting)
    g.eval(out + "h.run.st.gpost.n = 19; o.guild('Post 20'); o.guild('Post 21')", occ)
    w.tick(30)
    assert posts()[-1] == "Post 20" and "Post 21" not in posts(), posts()
    assert b.eval_py("return ns.EventLive:GetState(...).gpost.n", occ) == 20
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Trust
# ------------------------------------------------------------------------------------------------------------------
@case
def facts_from_outside_or_for_senses_the_def_doesnt_use_are_ignored():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b, c, d = cs
    occ = event(w, g, [b, c], """
        d.scores = { sc1 = { n = 'Kills', high = true, fmt = 'num', board = true } }
        S('k1', B:Stack(N('ev.happen', 'kill'), N('pt.add', 1, 'sc1', C('player'))))""")
    spy(g, occ)
    # Dain isn't in it; a loot fact (the def has no loot); a duel win claimed as a happening; a touch the def
    # doesn't use; a fact on GUILD instead of to the host
    raw_fact(d, occ, "{ k = 'h', what = 'kill', creature = 'Hogger' }")
    raw_fact(b, occ, "{ k = 'h', what = 'loot', item = 23424, count = 5 }")
    raw_fact(b, occ, "{ k = 'h', what = 'duel', other = 'Cora-Thunderstrike' }")
    raw_fact(b, occ, "{ k = 'touch', whom = 'Cora-Thunderstrike', how = 'click', near = true }")
    raw_fact(b, occ, "{ k = 'pos', map = 1951, x = 0.5, y = 0.5 }")
    raw_fact(b, occ, "{ k = 'h', what = 'kill', creature = 'Guild' }", dist="GUILD")
    w.tick(3)
    assert facts(g) == [], facts(g)
    assert run_st(g, occ, "pos") in (None, {}, []), run_st(g, occ, "pos")
    # a flood from one entrant (three messages of eight kills each, a changed addon): a burst of 16, then 4 a second
    b.eval("local occ = ...; for m = 1, 3 do local f = {}; for i = 1, 8 do f[i] = { k = 'h', what = 'kill', creature = 'Boar', "
           "at = GetServerTime() } end; ns.Comm:Send({ t = 'EVF', o = occ, k = 'b', f = f, at = GetServerTime() }, "
           "'WHISPER', 'Gina-Thunderstrike', 'event') end", occ)
    w.tick(1)
    n = len(facts(g, "Happen"))
    assert 16 <= n <= 18, n
    # the sensors' own: a pull of a dozen kills goes out in two messages a moment later, every kill counted
    g.eval("T_facts = {}")
    w.tick(5)
    a0 = len(w.addon_log)
    for i in range(12):
        cleu_kill(c, "Boar")
    w.tick(2)
    assert len(event_msgs(w, a0, "Cora")) == 2, len(event_msgs(w, a0, "Cora"))
    assert len(facts(g, "Happen")) == 12, len(facts(g, "Happen"))
    w.assert_no_errors()


@case
def nothing_is_sent_in_demo_mode_or_in_practice():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    occ = event(w, g, [b], """
        d.scores = { sc1 = { n = 'Kills', high = true, fmt = 'num', board = true } }
        S('k1', B:Stack(N('ev.happen', 'kill'), N('pt.add', 1, 'sc1', C('player'))))""")
    # Bert turns demo mode on: his sensors stop, and nothing goes out
    b.eval("ns.Demo:SetEnabled(true)")
    w.tick(1)
    assert b.eval("local a = ns.EventSensors:_State(); return next(a) == nil")
    a0 = len(w.addon_log)
    cleu_kill(b)
    assert b.eval("return ns.EventLive:SendFact(..., { k = 'h', what = 'kill' })", occ) is False
    w.tick(2)
    assert not event_msgs(w, a0, "Bert")
    b.eval("ns.Demo:SetEnabled(false)")
    w.tick(2)
    assert b.eval("local a = ns.EventSensors:_State(); return next(a) ~= nil")
    # practice: messages are logged (mine shown), nothing reaches the world
    listen(g)
    n0, a1 = len(w.chat_log), len(w.addon_log)
    out = g.eval_py(BUILD.replace("local function S", "local d = ns.EventBlocks:Blank('P')\nlocal function S") + """
        d.tags = { tg1 = { n = 'It', c = 'red', shown = 'all' } }
        S('p1', B:Stack(N('ev.start'), N('ch.show', N('pl.all'), 'Hello dummies'), N('ch.tell', N('pl.all'), 'A line'),
            N('ch.sound', 'warning', N('pl.all')), N('wo.plates', N('pl.all')), N('ch.guild', 'Practice post'),
            N('pl.tag', N('pl.all'), 'tg1')))
        local logs = {}
        ns:On('EVENT_PRACTICE_LOG', function(kind, text) logs[#logs + 1] = kind .. ': ' .. text end)
        local run = ns.EventLive:StartPractice(d, 4)
        ns.EventLive:PracticeHappen('Dummy1-Practice', 'kill', { creature = 'Boar' })
        return logs""")
    w.tick(5)
    for line in ("show: Hello dummies", "tell: Dummy 1, Dummy 2, Dummy 3, Dummy 4: A line", "guild: Practice post",
                 "plates: Dummy 1, Dummy 2, Dummy 3, Dummy 4"):
        assert line in out, (line, out)
    assert len([x for x in out if x.startswith("show:")]) == 1, out   # (logged once)
    assert len(w.chat_log) == n0
    assert not [e for e in event_msgs(w, a1, "Gina") if "practice" in str(e)]
    assert g.eval("return GetCVar('nameplateShowFriends')") == "0" and g.eval("return ns.db.eventPlates == nil")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Friendly nameplates
# ------------------------------------------------------------------------------------------------------------------
@case
def friendly_nameplates_are_hidden_for_the_event_and_put_back():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    b.eval("SetCVar('nameplateShowFriends', '1')")
    occ = event(w, g, [b], """
        S('n1', B:Stack(N('ev.start'), N('wo.plates', N('pl.all'))))
        S('n2', B:Stack(N('ev.happen', 'die'), N('ch.moment', 'x')))""")
    w.tick(2)
    cvar = "return GetCVar('nameplateShowFriends')"
    assert b.eval(cvar) == "0" and b.eval("return ns.db.eventPlates.was") == "1"
    # Shift+V turns them on again: hidden again at once
    b.eval("SetCVar('nameplateShowFriends', '1')")
    w.tick(1)
    assert b.eval(cvar) == "0"
    # a /reload while it runs: back at logout, hidden again once the event is there
    b.fire("PLAYER_LOGOUT")
    assert b.eval(cvar) == "1" and b.eval("return ns.db.eventPlates.on") is False
    b.relog()
    b.eval("SetCVar('nameplateShowFriends', '1')")   # (the client keeps CVars; the mock starts afresh)
    w.tick(15)
    assert b.eval(cvar) == "0", b.eval(cvar)
    # the event ends while Bert is in combat: they come back once combat ends
    b.eval("__MOCK.set_combat(true)")
    g.eval("ns.EventLive:EndEvent(...)", occ)
    w.tick(3)
    assert b.eval(cvar) == "0"
    b.eval("__MOCK.set_combat(false)")
    w.tick(1)
    assert b.eval(cvar) == "1" and b.eval("return ns.db.eventPlates == nil")
    # a crash left them hidden: back at the next login
    b.eval("ns.db.eventPlates = { was = '1', occs = { ogone = true }, on = true }; SetCVar('nameplateShowFriends', '0'); "
           "ns.EventSensors:OnLogin()")
    assert b.eval(cvar) == "1"
    w.tick(125)
    assert b.eval("return ns.db.eventPlates == nil")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The me-API: asks, buttons, tags, scores, the arrow
# ------------------------------------------------------------------------------------------------------------------
@case
def my_asks_buttons_tags_scores_and_arrow():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    w.set_position(b, NAGRAND, 0.5, 0.5)
    occ = event(w, g, [b, c], """
        d.tags = { tg1 = { n = 'Hiders', c = 'green', shown = 'all' }, tg2 = { n = 'It', c = 'red', shown = 'host' } }
        d.scores = { sc1 = { n = 'Finds', high = true, fmt = 'num', board = true },
                     sc2 = { n = 'Time', high = false, fmt = 'time', board = true } }
        d.places = { pc1 = { n = 'Tower', map = 1951, x = 0.5, y = 0.5 - 100 / 3683.33, r = 10 } }
        d.asks = { ak1 = { n = 'Vote', q = 'Who hides best?', kind = 'player', from = 'entrants', votes = 1, self = false,
                           time = 60, secret = true },
                   ak2 = { n = 'Score', q = 'Score it', kind = 'number', from = 'entrants', votes = 1, time = 60 } }
        S('a0', B:Stack(N('ev.start'),
            N('pl.tag', N('pl.all'), 'tg1'), N('pl.tag', N('pl.all'), 'tg2'),
            N('as.give', N('pl.all'), 'Ready'),
            N('pt.add', 3, 'sc1', N('pl.all')), N('pt.add', 2, 'sc1', N('pl.host')), N('pt.set', 'sc2', N('pl.all'), 70),
            N('pc.point', N('pl.all'), 'pc1'),
            N('as.ask', N('pl.all'), 'ak1')))
        S('a1', B:Stack(N('as.press', 'Ready'), N('ch.moment', J(C('player'), ' is ready'))))
        S('a2', B:Stack(N('as.on', 'ak1'), N('ch.moment', J(C('player'), ' voted'))))""")
    w.tick(2)
    assert b.eval_py("local out = {}; for _, t in ipairs(ns.EventLive:MyTags(...)) do out[#out + 1] = t.n end; return out",
                     occ) == ["Hiders"]
    # (the host sees the host's tags)
    assert len(g.eval_py("return ns.EventLive:MyTags(...)", occ)) == 2
    scores = b.eval_py("local out = {}; for _, s in ipairs(ns.EventLive:MyScores(...)) do "
                       "out[#out + 1] = { s.name, s.n, s.place, s.fmt } end; return out", occ)
    assert scores == [["Finds", 3, 2, "num"], ["Time", 70, 1, "time"]], scores
    assert b.eval_py("return ns.EventLive:MyButtons(...)", occ) == ["Ready"]
    asks = b.eval_py("local out = {}; for _, a in ipairs(ns.EventLive:MyAsks(...)) do "
                     "out[#out + 1] = { a.id, a.q, a.kind, a.players, a.answered, a.secret } end; return out", occ)
    assert asks == [["ak1", "Who hides best?", "player", [K("Gina"), K("Cora")], False, True]], asks
    # my answer (one each), and a button
    assert b.eval("return ns.EventLive:AnswerAsk2(..., 'ak1', 'Bert-Thunderstrike')", occ) is False   # not myself
    assert b.eval("return ns.EventLive:AnswerAsk2(..., 'ak1', 'Cora-Thunderstrike')", occ) is True
    assert b.eval("return ns.EventLive:AnswerAsk2(..., 'ak1', 'Gina-Thunderstrike')", occ) is False
    assert b.eval("return ns.EventLive:Press(..., 'Ready')", occ) is True
    assert b.eval("return ns.EventLive:Press(..., 'Hint')", occ) is False
    w.tick(2)
    assert run_st(g, occ, "qa.ak1.ans")[K("Bert")] == K("Cora")
    ms = moments(g, occ)
    assert "Bert is ready" in ms and "Bert voted" in ms, ms
    mine = b.eval_py("local a = ns.EventLive:MyAsks(...)[1]; return { a.answered, a.mine }", occ)
    assert mine == [True, K("Cora")], mine
    # (a secret ask's answers don't travel while it's open: Cora's copy says only that Bert answered)
    assert c.eval_py("return ns.EventLive:GetState(...).qa.ak1.ans['Bert-Thunderstrike']", occ) is True
    # the arrow: the Tower 100 yards north; facing north it's ahead, facing west it's to my right
    pid, yards, bearing = b.eval_py("return { ns.EventLive:MyPoint(...) }", occ)
    assert pid == "pc1" and abs(yards - 100) < 1 and min(bearing, 2 * math.pi - bearing) < 0.01, (pid, yards, bearing)
    b.eval("__MOCK.facing = math.pi / 2")
    bearing = b.eval_py("return { ns.EventLive:MyPoint(...) }", occ)[2]
    assert abs(bearing - 3 * math.pi / 2) < 0.01, bearing
    # in an instance: the place, but no yards or bearing
    w.enter_instance("Mana-Tombs", 557, "party", 5, clients=[b])
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == ["pc1"]
    w.assert_no_errors()


@case
def practice_inputs_and_dummies_answer_by_themselves():
    w, cs = guild(["Gina"], tick=5)
    g = cs[0]
    out = g.eval_py(BUILD.replace("local function S", "local d = ns.EventBlocks:Blank('P')\nlocal function S") + """
        d.scores = { sc1 = { n = 'Kills', high = true, fmt = 'num', board = true },
                     sc2 = { n = 'Votes', high = true, fmt = 'num', board = true } }
        d.places = { pc1 = { n = 'Ring', map = 1951, x = 0.5, y = 0.5, r = 30 } }
        d.asks = { ak1 = { n = 'Rate', q = 'Rate it', kind = 'number', from = 'entrants', votes = 1, time = 60 },
                   ak2 = { n = 'Pick', q = 'Who?', kind = 'player', from = 'entrants', votes = 2, self = false, time = 60 } }
        S('p1', B:Stack(N('ev.start'), N('as.ask', N('pl.all'), 'ak1'), N('as.ask', N('pl.all'), 'ak2'),
            N('as.give', N('pl.all'), 'Go')))
        S('p2', B:Stack(N('as.on', 'ak1'), N('pt.add', C('answer'), 'sc2', C('player'))))
        S('p3', B:Stack(N('ev.happen', 'kill'), N('pt.add', 1, 'sc1', C('player'))))
        S('p4', B:Stack(N('pc.enter', 'pc1'), N('ch.moment', J(C('player'), ' is in'))))
        S('p5', B:Stack(N('pl.touch', nil, nil, 'click'), N('ch.moment', J(C('toucher'), ' tags ', C('touched')))))
        S('p6', B:Stack(N('as.press', 'Go'), N('ch.moment', J(C('player'), ' goes'))))
        local L = ns.EventLive
        local run = L:StartPractice(d, 4)
        L:PracticeHappen('Dummy1-Practice', 'kill', { creature = 'Boar' })
        L:PracticePlace('Dummy2-Practice', 'pc1', true)
        L:PracticeTouch('Dummy3-Practice', 'Dummy4-Practice', 'click')
        L:PracticeAnswer('Dummy1-Practice', 'ak1', 7)
        return { kills = run.st.scores.sc1['Dummy1-Practice'] }""")
    assert out == {"kills": 1}, out
    # ("ask" waits for its answers: the second ask, then the button, come once the first closed)
    w.tick(20)
    g.eval("ns.EventLive:PracticePress('Dummy4-Practice', 'Go')")
    st = g.eval_py("""local run = ns.EventLive:GetPractice()
        local n = 0
        for k, v in pairs(run.st.qa.ak1.ans) do n = n + 1 end
        local picks = run.st.qa.ak2.ans['Dummy2-Practice']
        local m = {}
        for _, x in ipairs(run.st.moments) do m[#m + 1] = x.text end
        return { answered = n, open = run.st.qa.ak1.open, votes = run.st.scores.sc2['Dummy1-Practice'], picks = picks and #picks,
                 m = m }""")
    # every dummy answered (Dummy 1's 7 stands: one answer each), the two-vote ask got two picks
    assert st["answered"] == 4 and st["open"] is False and st["votes"] == 7 and st["picks"] == 2, st
    for m in ("Dummy 2 is in", "Dummy 3 tags Dummy 4", "Dummy 4 goes"):
        assert m in st["m"], (m, st["m"])
    g.eval("ns.EventLive:StopPractice()")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Data: definitions, Migrate, results, sync caps
# ------------------------------------------------------------------------------------------------------------------
@case
def clean_def_keeps_the_definitions_within_their_limits():
    w, cs = guild(["Gina"], tick=3)
    g = cs[0]
    out = g.eval_py("""
        local B, Ev, H = ns.EventBlocks, ns.Events, ns.Util.Hash
        local same = {}
        for _, ex in ipairs(B:Examples()) do
          local d = ex.def
          d.id, d.by = 'e' .. ex.key, 'Gina-Thunderstrike'
          local c1 = Ev:CleanDef(d)
          local c2 = Ev:CleanDef(c1)
          local kinds = {}
          for _, k in ipairs({ 'tags', 'scores', 'places', 'lists', 'asks' }) do
            local n = 0
            for _ in pairs(c1[k] or {}) do n = n + 1 end
            local m = 0
            for _ in pairs(d[k] or {}) do m = m + 1 end
            if n ~= m then kinds[#kinds + 1] = k end
          end
          same[#same + 1] = { ex.key, H(c1) == H(c2), #kinds }
        end
        -- past the limits
        local d = B:Blank('Big')
        d.id, d.by = 'ebig1', 'Gina-Thunderstrike'
        d.places = {}
        for i = 1, 30 do d.places['pc' .. i] = { n = string.rep('N', 40), map = 1951, x = 0.5, y = 2, r = 99999 } end
        d.lists = { ls1 = { n = 'Q', kind = 'question', items = {} }, ls2 = { n = 'T', kind = 'text', items = {} } }
        for i = 1, 50 do
          d.lists.ls1.items[i] = { q = string.rep('q', 200), a = { 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8' }, pts = 5 }
          d.lists.ls2.items[i] = 'item ' .. i
        end
        d.asks = { ak1 = { n = 'A', q = 'Pick|cff one', kind = 'choice', choices = { 'a', 'b', 'c', 'd', 'e', 'f', 'g' },
                           votes = 9, time = 99999, from = 'bad id!' } }
        d.tags = { tg1 = { n = 'T', c = 'nocolour', shown = 'nobody' } }
        d.scores = { sc1 = { n = 'S', fmt = 'weird', cap = 0 / 0 } }
        local c = Ev:CleanDef(d)
        local np = 0
        for _ in pairs(c.places) do np = np + 1 end
        local q = c.lists.ls1.items[1]
        return { same = same, places = np, name = #c.places.pc1.n, y = c.places.pc1.y, r = c.places.pc1.r,
                 qn = #c.lists.ls1.items, tn = #c.lists.ls2.items, ql = #q.q, an = #q.a, ask = c.asks.ak1,
                 tag = c.tags.tg1, score = c.scores.sc1 }""")
    for key, same, kinds in out["same"]:
        assert same and kinds == 0, (key, same, kinds)
    assert len(out["same"]) == 8, out["same"]
    assert out["places"] == 24 and out["name"] == 24 and out["y"] == 1 and out["r"] == 5000, out
    assert out["qn"] == 40 and out["tn"] == 40 and out["ql"] == 120 and out["an"] == 6, out
    ask = out["ask"]
    assert ask["q"] == "Pickcff one" and len(ask["choices"]) == 6 and ask["votes"] == 3 and ask["time"] == 3600, ask
    assert ask["from"] == "entrants", ask
    assert out["tag"] == {"n": "T", "c": "blue", "shown": "all"}, out["tag"]
    assert out["score"]["fmt"] == "num" and out["score"].get("cap") is None, out["score"]
    w.assert_no_errors()


@case
def a_def_with_every_definition_filled_in_still_fits():
    w, cs = guild(["Gina", "Bert"], tick=HELLO)
    g, b = cs
    fill = """
        local random = ...
        local B, Ev = ns.EventBlocks, ns.Events
        local L = B.LIMITS
        local seed = 7
        local WORDS = { 'the', 'a', 'which', 'boss', 'raid', 'drops', 'what', 'name', 'zone', 'item', 'quest', 'Illidan',
          'Kael', 'Vashj', 'tier', 'token', 'year', 'first', 'guild', 'Nagrand', 'who', 'where', 'Shattrath', 'Karazhan',
          'Gruul', 'Magtheridon', 'Lady', 'Prince', 'Netherspite', 'Curator', 'Moroes', 'Attumen', 'Opera', 'Aran',
          'Terestian', 'Nightbane', 'chess', 'mount', 'pet', 'reputation' }
        local function words(n)
          local t = {}
          while #table.concat(t, ' ') < n do
            seed = (seed * 16807) % 2147483647
            if random then
              local s = {}
              for i = 1, 6 do seed = (seed * 16807) % 2147483647; s[i] = string.char(97 + seed % 26) end
              t[#t + 1] = table.concat(s)
            else
              t[#t + 1] = WORDS[seed % #WORDS + 1]
            end
          end
          return table.concat(t, ' '):sub(1, n)
        end
        local d = Ev:NewDef(true)
        d.name = random and 'Noise' or 'Everything'
        d.tags, d.scores, d.places, d.lists, d.asks = {}, {}, {}, {}, {}
        for i = 1, L.defs do
          d.tags['tg' .. i] = { n = words(L.name), c = 'green', shown = 'all' }
          d.scores['sc' .. i] = { n = words(L.name), high = true, fmt = 'num', board = true, cap = 100 }
          d.asks['ak' .. i] = { n = words(L.name), q = words(L.question), kind = 'choice', choices = {}, from = 'entrants',
            votes = 3, self = true, time = 600, secret = true }
          for j = 1, L.choices do d.asks['ak' .. i].choices[j] = words(L.choice) end
        end
        for i = 1, L.places do
          d.places['pc' .. i] = { n = words(L.name), map = 1951, x = (i * 37 % 100) / 100 + 0.00123,
            y = (i * 53 % 100) / 100 + 0.00456, r = 40, z = words(20), sz = words(24) }
        end
        for i = 1, L.defs do
          local l = { n = words(L.name), kind = 'question', items = {} }
          for j = 1, L.items do
            local it = { q = words(L.question), a = {}, pts = 1 }
            for k = 1, L.answers do it.a[k] = words(L.answer) end
            l.items[j] = it
          end
          d.lists['ls' .. i] = l
        end
        local ok = Ev:SaveDef(d)
        local clean = Ev:CleanDef(d) or {}
        local items = 0
        for _, l in pairs(clean.lists or {}) do items = items + #l.items end
        local fits, wire = ns.Comm:Fits({ t = 'EVU', k = 'D', r = clean }, 0.1)
        return { ok = ok, fits = fits, wire = wire, items = items, stored = Ev:GetDef(d.id) ~= nil }"""
    # every definition at its limit, the list items at the event's total (80), the starter's pieces besides: it
    # goes to the guild in one message, with room to spare
    out = g.eval_py(fill, False)
    assert out["ok"] is True and out["fits"] is True and out["items"] == 80 and out["wire"] < 18000, out
    # (13 KB: about 50 parts on the wire at the server's pace of one a second for a prefix)
    w.tick(70, step=0.5)
    assert b.eval("local n = 0; for _, d in ipairs(ns.Events:GetDefs()) do if d.name == 'Everything' then n = n + 1 end end; "
                  "return n") == 1
    # the worst case (every text random letters, nothing to pack) is too big: refused, not stored, and said so
    n0 = len(g.chat_frame)
    out = g.eval_py(fill, True)
    assert out["ok"] is False and out["stored"] is False, out
    assert any("too big to share" in str(x) for x in g.chat_frame[n0:]), g.chat_frame[n0:]
    w.assert_no_errors()


@case
def migrate_on_load_receive_and_in_demo_data():
    w, cs = guild(["Gina", "Bert"])
    g, b = cs
    old = """
        local d = { id = %r, by = 'Bert-Thunderstrike', rev = GetServerTime(), at = GetServerTime(), name = 'Old cup',
          stages = { { id = 's1', name = 'One' } }, blocks = {}, vars = {}, badges = {}, notes = {},
          scripts = { { id = 'o1', st = '*', x = 0, y = 0, top = { k = 'ev.duel', a = {},
            n = { k = 'ch.wh', a = { { k = 'ctx', a = { 'winner' } }, 'You won' },
            n = { k = 'pt.add', a = { 1, 'Wins', { k = 'ctx', a = { 'winner' } } } } } } } } }
    """
    # stored by a version before part 2, and found at login: migrated
    b.eval("ns.Events:SetTitle('')\nlocal d" + (old % "eold1").split("local d", 1)[1]
           + "\nns.db.events[ns.Guild:GetGuildKey()].D[d.id] = d")
    b.relog()
    w.tick(5)
    mig = b.eval_py("""local d = ns.Events:GetDef('eold1')
        local top = d.scripts[1].top
        local sc
        for id, s in pairs(d.scores or {}) do if s.n == 'Wins' then sc = id end end
        return { top.k, top.a[1], top.n.k, top.n.n.a[2] == sc and sc ~= nil }""")
    assert mig == ["ev.happen", "duel", "ch.tell", True], mig
    # received from a member with the old pieces: stored as part 2's
    g.eval("local d" + (old % "eold2").split("local d", 1)[1].replace("'Bert-Thunderstrike'", "'Gina-Thunderstrike'")
           + "\nns.Comm:Send({ t = 'EVU', k = 'D', r = d }, 'GUILD', nil, 'data')")
    w.tick(5)
    got_ = b.eval_py("local d = ns.Events:GetDef('eold2'); return d and { d.scripts[1].top.k, d.scripts[1].top.n.k }")
    assert got_ == ["ev.happen", "ch.tell"], got_
    # demo mode's events: none has an old piece, and the new kinds are there
    demo = b.eval_py("""ns.Demo:SetEnabled(true)
        local old = { ['ev.duel'] = true, ['ch.wh'] = true, ['ch.rw'] = true, ['ch.say'] = true, ['pt.vset'] = true }
        local bad, kinds = 0, {}
        local function check(d)
          ns.EventBlocks:EachScript(d, function(s) ns.EventBlocks:Walk(s.top, function(p) if old[p.k] then bad = bad + 1 end end) end)
          for _, k in ipairs(ns.EventBlocks:Kinds(d, true)) do kinds[k] = true end
        end
        for _, d in ipairs(ns.Events:GetDefs()) do check(d) end
        for _, o in ipairs(ns.Events:GetOccurrences()) do check(o.def) end
        local r = ns.Events:GetResult('rdemo3')
        return { bad = bad, tags = kinds.tags or false, places = kinds.places or false, asks = kinds.asks or false,
                 fish = r and r.scores and r.scores[1].n }""")
    assert demo == {"bad": 0, "tags": True, "places": True, "asks": True, "fish": "Fish"}, demo
    w.assert_no_errors()


@case
def a_new_host_learns_where_everyone_is_and_its_messages_are_heard():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b, c, d = cs
    for x, dx in ((g, 0), (b, 2), (c, 5), (d, 10)):
        w.set_position(x, NAGRAND, 0.5 + dx * YD, 0.5)
    occ = event(w, g, [b, c, d], """
        d.places = { pc1 = { n = 'Ring', map = 1951, x = 0.5, y = 0.5, r = 30 } }
        S('p1', B:Stack(N('pc.leave', 'pc1'), N('ch.tell', N('pl.all'), J(C('player'), ' left the ring'))))
        S('p2', B:Stack(N('ev.happen', 'mount'), N('ch.moment', J(C('player'), ' mounts'))))""")
    c.eval("__MOCK.mounted = true")
    w.tick(3)
    assert run_st(g, occ, "flags")[K("Cora")]["mounted"] is True
    listen(c, d)
    # the host is gone: Bert (first in name order) takes over, from a state without who is where
    g.logout()
    w.tick(80)
    assert b.eval("return ns.EventLive:IsHostOf(...)", occ)
    w.tick(3)
    inside = run_st(b, occ, "inplace")["pc1"]
    assert sorted(inside.keys()) == [K("Bert"), K("Cora"), K("Dain")], inside
    assert run_st(b, occ, "flags")[K("Cora")]["mounted"] is True, run_st(b, occ, "flags")
    # Cora rides out of the ring: the new host's run hears it, and its line reaches the others
    w.set_position(c, NAGRAND, 0.5 + 60 * YD, 0.5)
    w.tick(5)
    for x in (c, d):
        assert ("EVENT_TELL", occ, "Cora left the ring") in got(x), (x.name, got(x))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# End to end: across four clients
# ------------------------------------------------------------------------------------------------------------------
@case
def a_live_hide_and_seek_across_four_clients():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, cs = guild(names)
    by = {c.name: c for c in cs}
    g = by["Gina"]
    # everyone near the middle of the play area (Nagrand, Halaa), a few yards apart
    for i, c in enumerate(cs):
        w.set_position(c, NAGRAND, 0.415 + i * 4 * YD, 0.47, subzone="Halaa")
    for c in cs:
        c.eval("SetCVar('nameplateShowFriends', '1')")
    occ = example(w, g, cs[1:], "hide", SHORT_TIMERS + "shorten(20, 'Hide')")
    listen(*cs)
    ok = g.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(3)
    st = g.eval_py("local st = ns.EventLive:GetState(...); return { stage = st.stage, hiders = st.tags.tg1, seekers = st.tags.tg2 }",
                   occ)
    assert st["stage"] == "s2", st
    seekers = sorted(st["seekers"].keys())
    hiders = sorted(st["hiders"].keys())
    assert len(seekers) == 1 and len(hiders) == 3 and seekers[0] not in hiders, st
    seeker = by[seekers[0].split("-")[0]]
    hider_cs = [by[k.split("-")[0]] for k in hiders]
    # the screens said who hides and who seeks, and the hiders' arrows point to the play area
    for c in hider_cs:
        assert any(x[0] == "EVENT_SHOW" and x[2].startswith("Hide in the play area") for x in got(c)), (c.name, got(c))
    assert any(x[0] == "EVENT_SHOW" and x[2].startswith("You seek") for x in got(seeker)), got(seeker)
    # (they stand in the play area already: their arrow to it is done)
    w.tick(3)
    assert hider_cs[0].eval_py("return { ns.EventLive:MyPoint(...) }", occ) == []
    # a hider walks out of the play area: told to go back, and the arrow points there again
    far = hider_cs[0]
    w.set_position(far, NAGRAND, 0.415 + 700 * YD, 0.47, subzone="Sunspring Post")
    w.tick(5)
    assert far.eval_py("return ns.EventLive:MyFeed(...)[1].text", occ) == "Go back to the play area"
    pid, yards, _ = far.eval_py("return { ns.EventLive:MyPoint(...) }", occ)
    assert pid == "pc1" and abs(yards - 700) < 2, (pid, yards)
    w.set_position(far, NAGRAND, 0.415 + 30 * YD, 0.47, subzone="Halaa")
    # seeking: a Hint button, the seeker's friendly nameplates off
    w.tick(25)
    assert g.eval_py("return ns.EventLive:GetState(...).stage", occ) == "s3"
    w.tick(2)
    assert seeker.eval_py("return ns.EventLive:MyButtons(...)", occ) == ["Hint"]
    assert seeker.eval("return GetCVar('nameplateShowFriends')") == "0"
    assert hider_cs[1].eval("return GetCVar('nameplateShowFriends')") == "1"
    assert seeker.eval("return ns.EventLive:Press(..., 'Hint')", occ)
    w.tick(2)
    assert seeker.eval_py("return ns.EventLive:MyFeed(...)[1].text", occ) == "Nearest hider: Halaa"
    assert seeker.eval_py("return ns.EventLive:MyButtons(...)", occ) == []
    # a /target macro doesn't find anyone (and says so); clicks up close do
    seeker.eval("__MOCK.target_player(...)", hider_cs[0].name)
    w.tick(5)   # (the host's event prefix carries its states too: a line may take a few seconds)
    feed = seeker.eval_py("local out = {}; for _, e in ipairs(ns.EventLive:MyFeed(...)) do out[#out + 1] = e.text end; "
                          "return out", occ)
    assert feed[0] == "Click them to find them. Macros don't count", (feed, seeker.name, hider_cs[0].name, run_st(g, occ, "tags"))
    sx = 0.415 + names.index(seeker.name) * 4 * YD
    for i, h in enumerate(hider_cs):
        w.set_position(seeker, NAGRAND, sx, 0.47)
        w.set_position(h, NAGRAND, sx + 3 * YD, 0.47, subzone="Halaa")
        w.tick(3)
        seeker.eval("__MOCK.click_player(...)", h.name)
        w.tick(3)
    w.tick(5)
    st = g.eval_py("local st = ns.EventLive:GetState(...); return { phase = st.phase, found = st.tags.tg3 }", occ)
    assert st["phase"] == "done", st
    assert sorted(st["found"].keys()) == hiders, st
    assert score(g, occ, "sc1", seeker.name) == 3
    # the seeker's nameplates are back; the result has the scores' tables and the tags, on everyone
    w.tick(5)
    assert seeker.eval("return GetCVar('nameplateShowFriends')") == "1"
    for c in cs:
        r = c.eval_py("""local r = ns.Events:GetResult(...)
            if not r then return nil end
            local out = { champ = r.champ, scores = {}, tags = {} }
            for _, s in ipairs(r.scores or {}) do out.scores[s.n] = s.v end
            for _, t in ipairs(r.tags or {}) do out.tags[t.n] = #t.k end
            return out""", occ)
        assert r and r["scores"]["Finds"] == {seekers[0]: 3} and r["tags"]["Found"] == 3, (c.name, r)
        assert len(r["scores"]["Hidden"]) == 3, (c.name, r)
    guild_lines = [e["text"] for e in w.chat_log if e["chat_type"] == "GUILD"]
    assert any(t.endswith("stayed hidden the longest in hide and seek!") for t in guild_lines), guild_lines
    w.assert_no_errors()


@case
def a_live_fishing_derby_across_four_clients():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, cs = guild(names)
    by = {c.name: c for c in cs}
    g = by["Gina"]
    occ = example(w, g, cs[1:], "fish", SHORT_TIMERS + "shorten(60)")
    listen(*cs)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)
    assert g.eval_py("return ns.EventLive:GetState(...).stage", occ) == "s2"
    for c in cs:
        assert ("EVENT_SHOW", occ, "Fish! 30 minutes: every fish counts.") in got(c), (c.name, got(c))
    # Bert 3 fish, Cora 2 (one of them Mr. Pinchy), Dain 1, Gina (the host) none
    catches = {"Bert": [27422, 27425, 27422], "Cora": [27422, 27820], "Dain": [27425]}
    g.eval("ns.EventLive:_State()")
    for n, items in catches.items():
        for it in items:
            by[n].eval("__MOCK.fish_loot({ { %d, 1 } })" % it)
            w.tick(1)
    # (Mr. Pinchy by name: the mock names unknown items "Item <id>")
    by["Cora"].eval("__MOCK.fishing_loot = true")
    by["Cora"].fire("LOOT_OPENED", True, False)
    loot_line(by["Cora"], 27388, "Mr. Pinchy")
    by["Cora"].eval("__MOCK.fishing_loot = false")
    by["Cora"].fire("LOOT_CLOSED")
    w.tick(10)
    assert score(g, occ, "sc1", "Bert") == 3 and score(g, occ, "sc1", "Cora") == 3 and score(g, occ, "sc1", "Dain") == 1, (
        score(g, occ, "sc1", "Bert"), score(g, occ, "sc1", "Cora"))
    assert "Cora fished up Mr. Pinchy" in moments(by["Dain"], occ), moments(by["Dain"], occ)
    # the lead changes are told to everyone
    feed = by["Dain"].eval_py("local out = {}; for _, e in ipairs(ns.EventLive:MyFeed(...)) do out[#out + 1] = e.text end; "
                              "return out", occ)
    assert any(x.startswith("Bert leads with") for x in feed), feed
    # Bert's tracker: his fish and his place
    assert by["Bert"].eval_py("local s = ns.EventLive:MyScores(...)[1]; return { s.name, s.n, s.place }", occ) == ["Fish", 3, 1]
    w.tick(70)
    st = g.eval_py("return ns.EventLive:GetState(...).phase", occ)
    assert st == "done", st
    w.tick(5)
    for c in cs:
        r = c.eval_py("local r = ns.Events:GetResult(...); return r and { champ = r.champ, fish = r.scores and r.scores[1].v }", occ)
        assert r and r["champ"] == K("Bert") and r["fish"] == {K("Bert"): 3, K("Cora"): 3, K("Dain"): 1}, (c.name, r)
    guild_lines = [e["text"] for e in w.chat_log if e["chat_type"] == "GUILD"]
    assert "Bert wins the fishing derby with 3 fish!" in guild_lines, guild_lines
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
