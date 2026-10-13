"""Raid features (1.2): in a raid, loot distribution and rolls are off until the raid leader starts a raid session,
and the session says which of them it runs.

Covers: no session = no drops, no rolls (for the leader and for raiders); Start raid opening the window from the
session bar and from the Raids tab; starting with everything, without loot distribution, without rolls, without the BiS
lock; changing the features of a running session (Options); the features following the session to a new raid
leader and surviving the leader's /reload (also a new leader's); ending the raid switching everything off again; a
leader back from a game crash (nothing or an out of date copy saved) asking the raid which session runs, two agreeing
answers needed, only the leader answered, no question in a raid made while everyone is logged in; a session from a
raid leader on an older version (no feature list) running everything; malformed feature lists; a raider who doesn't know
the rules yet taking an announced drop; the window as a demo outside a raid; /dz raid start | options; dungeon mode
and /dz test staying as they were.
1.3: "loot distribution" is the loot council. Without it, rolls (when on) still bring up the drop panel, as a plain
roll panel (Roll:IsPlainRaid), and the loot handed out is recorded whatever runs (also before Start raid); the BiS
lock needs the loot council in the Start raid window.

Run: luaenv\\Scripts\\python.exe tests\\raidlog\\test_raid_features.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import World, Client, gm_pick, case, run_all, printed_since  # noqa: E402

REALM = "Thunderstrike"
RUBY_DRAPE = 28653          # Karazhan, Moroes... any epic of the item data


def K(name):
    return "%s-%s" % (name, REALM)


def world(session=None):
    """Lee leads a raid of Gina (GM), Bob (council), Lee and Rita. session: a features table to start with."""
    w = World()
    w.auto_session = False
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    w.make_raid(list(c.values()), leader=c["Lee"])
    w.tick(8)
    if session is not None:
        start(c["Lee"], session)
        w.tick(3)
    return w, c


def start(cl, features=None):
    return cl.eval_py("local ok, e = ns.GroupRules:SetSession(true, nil, ...); return { ok = ok, e = e }", features)


def on(cl, name):
    return cl.eval("return ns.GroupRules:IsFeatureOn(...)", name)


def feats(cl):
    f = cl.eval_py("return ns.GroupRules:GetSessionFeatures()")
    return None if f is None else {k: bool(f[k]) for k in ("loot", "rolls", "lock")}


def drops(cl):
    return cl.eval("local n = 0; for _, d in ipairs(ns.Loot:GetHistory()) do if not d.test then n = n + 1 end end; return n")


def epic(cl):
    return cl.eval("return ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID")


def loot(w, cl, item, tick=3):
    cl.open_loot([(item, 4)])
    w.tick(tick)
    cl.close_loot() if hasattr(cl, "close_loot") else None


def rolls(cl):
    return cl.eval("local n = 0; for _ in pairs(ns.Roll:GetAll and ns.Roll:GetAll() or {}) do n = n + 1 end; return n")


def plain(cl):
    """1.3: a roll started now rolls plain (rolls on, loot council off): the drop panel is a plain roll panel."""
    return cl.eval("return ns.Roll:IsPlainRaid()")


def logged(cl):
    """The Loot Log as this client holds it: [(winner, itemID)] (council clients record)."""
    return [(e["w"], e["i"]) for e in cl.eval_py(
        "local out = {}; for _, e in ipairs(ns.Ledger:GetEntries()) do out[#out + 1] = { w = e.w, i = e.i } end; "
        "return out") or []]


WIN = "ns.SessionBar:GetStartWindow()"


# ------------------------------------------------------------------------------------------------------------------
@case
def without_a_session_the_raid_has_no_loot_and_no_rolls():
    w, c = world()
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    item = epic(lee)
    for x in c.values():
        assert on(x, "loot") is False and on(x, "rolls") is False and feats(x) is None
        assert x.eval("return ns.Roll:CanStart()") is False
    # a boss is looted: nobody tracks or announces it
    loot(w, bob, item)
    for x in c.values():
        assert drops(x) == 0, drops(x)
    # /dz drop and a roll are refused, with the reason
    p0 = len(bob.chat_frame)
    bob.eval("ns.Loot:ManualDrop('item:' .. ...)", item)
    assert any("The loot council and rolls are off" in l for l in printed_since(bob, p0)), printed_since(bob, p0)
    p0 = len(bob.chat_frame)
    assert bob.eval("return ns.Roll:StartAll({ s = 'X-1', b = '', i = { ... } })", item) == 0
    assert any("when the raid leader starts the raid" in l for l in printed_since(bob, p0)), printed_since(bob, p0)
    w.tick(2)
    for x in c.values():
        assert drops(x) == 0 and x.eval("return ns.Roll:GetActive()") is None
    # /dz test still shows a (local) test drop
    lee.slash("/dz test")
    w.tick(1)
    assert lee.eval("return #ns.Loot:GetHistory()") == 1 and drops(rita) == 0
    w.assert_no_errors()


@case
def starting_with_everything_switches_it_all_on():
    w, c = world(session={"loot": True, "rolls": True, "lock": True})
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    for x in c.values():
        assert on(x, "loot") and on(x, "rolls"), x.name
        assert feats(x) == {"loot": True, "rolls": True, "lock": True}
        assert x.eval("return ns.GroupRules:IsLocked()") is True
    assert bob.eval("return ns.Roll:CanStart()") is True and rita.eval("return ns.Roll:CanStart()") is False
    loot(w, bob, epic(bob))
    for x in c.values():
        assert drops(x) == 1, (x.name, drops(x))
    # ending the raid: off again
    assert lee.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    for x in c.values():
        assert on(x, "loot") is False and on(x, "rolls") is False
        assert x.eval("return ns.GroupRules:IsLocked()") is False
    w.assert_no_errors()


@case
def a_raid_without_loot_distribution_or_without_rolls():
    # no loot distribution, rolls on, no lock
    w, c = world(session={"loot": False, "rolls": True, "lock": False})
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    for x in c.values():
        assert feats(x) == {"loot": False, "rolls": True, "lock": False}, feats(x)
        assert on(x, "loot") is False and on(x, "rolls") is True
        assert x.eval("return ns.GroupRules:IsLocked()") is False
        assert x.eval("return ns.GroupRules:GetSession() ~= nil") is True      # the raid log still runs
    item = epic(bob)
    # 1.3: rolls without the loot council still bring up the drop panel, as a plain roll panel
    loot(w, bob, item)
    assert all(drops(x) == 1 for x in c.values()), [drops(x) for x in c.values()]
    assert all(plain(x) is True for x in c.values())
    assert bob.eval("return ns.Roll:CanStart()") is True
    assert bob.eval("return ns.Roll:Start(...) ~= nil", item) is True
    w.tick(2)
    assert rita.eval("return ns.Roll:GetActive() ~= nil") is True
    assert rita.eval("return ns.Roll:GetActive().plain") is True and bob.eval("return ns.Roll:GetActive().plain") is True
    # Options: the leader switches loot on and rolls off during the raid
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                      {"loot": True, "rolls": False, "lock": True})
    assert res["ok"] is True, res
    w.tick(3)
    for x in c.values():
        assert feats(x) == {"loot": True, "rolls": False, "lock": True}, (x.name, feats(x))
        assert x.eval("return ns.GroupRules:IsLocked()") is True
        assert plain(x) is False
    assert bob.eval("return ns.Roll:CanStart()") is False
    c["Gina"].open_loot([(epic(bob), 4)], source_guid="Creature-0-1-2-3-15691-000ABD")
    w.tick(3)
    assert all(drops(x) == 2 for x in c.values()), [drops(x) for x in c.values()]
    # with neither the council nor rolls nothing comes up (the loot handed out is still recorded)
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                      {"loot": False, "rolls": False, "lock": False})
    assert res["ok"] is True, res
    w.tick(3)
    c["Gina"].open_loot([(epic(bob), 4)], source_guid="Creature-0-1-2-3-15692-000ABE")
    w.tick(3)
    assert all(drops(x) == 2 for x in c.values()), [drops(x) for x in c.values()]
    # only the leader of a running session changes them
    res = bob.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures({}); return { ok = ok, e = e }")
    assert res["ok"] is False
    w.assert_no_errors()


@case
def the_start_raid_window():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    bar = "ns.SessionBar:GetFrame()"
    assert lee.eval("return %s:IsShown()" % bar) is True
    # 1.4.2: the crest's line starts the raid itself (tests/raidlog/test_raidlog.py); the window is the Raids tab's and
    # /dz raid options'
    assert lee.eval("return %s.line.start:IsShown()" % bar) is True
    lee.eval("ns.SessionBar:OpenStart()")
    w.tick(0.2)
    assert lee.eval("return %s:IsShown()" % WIN) is True and lee.eval("return ns.GroupRules:GetSession()") is None
    assert lee.find_text("Loot council", True, True) and lee.find_text("Lock everyone's BiS lists", True, True)
    assert lee.find_text("the loot handed out are always logged", True, True)
    for key in ("loot", "rolls", "lock"):
        assert lee.eval("return %s.boxes[...]:GetChecked()" % WIN, key) is True, key
    # the BiS lock needs the loot council: without it the box is greyed out and off
    lee.click(lee.eval("return %s.boxes.loot" % WIN))
    assert lee.eval("return %s.boxes.lock:IsEnabled()" % WIN) is False
    assert lee.eval("return %s.boxes.lock:GetChecked()" % WIN) is False
    lee.click(lee.eval("return %s.boxes.loot" % WIN))
    assert lee.eval("return %s.boxes.lock:IsEnabled()" % WIN) is True
    lee.click(lee.eval("return %s.boxes.lock" % WIN))
    assert lee.eval("return %s.boxes.lock:GetChecked()" % WIN) is True
    # untick rolls, start
    lee.click(lee.eval("return %s.boxes.rolls" % WIN))
    lee.click(lee.eval("return %s.startBtn" % WIN))
    w.tick(3)
    assert lee.eval("return %s:IsShown()" % WIN) is False
    for x in c.values():
        assert feats(x) == {"loot": True, "rolls": False, "lock": True}, (x.name, feats(x))
    assert lee.eval("return ns.SessionBar:GetInfo().feats.rolls") is False
    # Options (the leader only): the window again, with what runs now; Apply changes it
    lee.slash("/dz raid options")
    w.tick(0.2)
    assert lee.eval("return %s.startBtn:GetText()" % WIN) == "Apply"
    assert lee.eval("return %s.boxes.rolls:GetChecked()" % WIN) is False
    lee.click(lee.eval("return %s.boxes.rolls" % WIN))
    lee.click(lee.eval("return %s.boxes.lock" % WIN))
    lee.click(lee.eval("return %s.startBtn" % WIN))
    w.tick(3)
    for x in c.values():
        assert feats(x) == {"loot": True, "rolls": True, "lock": False}, (x.name, feats(x))
    assert rita.eval("return ns.SessionBar:OpenOptions()") is False
    # the choice is remembered for the next raid, also by /dz raid start
    assert lee.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    lee.slash("/dz raid start")
    w.tick(3)
    assert feats(rita) == {"loot": True, "rolls": True, "lock": False}
    # the Raids tab's Start raid opens the same window
    assert lee.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    lee.slash("/dz raids")
    w.tick(0.5)
    lee.click(lee.eval("return ns.RaidsUI:GetPanel().sessionBtn"))
    w.tick(0.2)
    assert lee.eval("return %s:IsShown()" % WIN) is True and lee.eval("return %s.startBtn:GetText()" % WIN) == "Start raid"
    assert lee.eval("return ns.GroupRules:GetSession()") is None
    w.assert_no_errors()


@case
def the_features_follow_the_session():
    w, c = world(session={"loot": True, "rolls": False, "lock": False})
    lee, bob, rita, gina = c["Lee"], c["Bob"], c["Rita"], c["Gina"]
    want = {"loot": True, "rolls": False, "lock": False}
    # the leader reloads: the same session, the same features
    lee.relog()
    w.tick(10)
    for x in c.values():
        assert feats(x) == want, (x.name, feats(x))
    # a new raid leader adopts the session with its features
    rid = rita.eval("return ns.GroupRules:GetSession().id")
    w.make_raid([gina, bob, rita, lee], leader=bob)
    w.tick(12)
    for x in c.values():
        s = x.eval_py("return ns.GroupRules:GetSession()")
        assert s and s["id"] == rid and s["by"] == K("Bob"), (x.name, s)
        assert feats(x) == want, (x.name, feats(x))
    w.assert_no_errors()


@case
def a_new_leader_who_reloads_keeps_loot_off():
    # in game (Magtheridon): the raid lead changed after Start raid without loot distribution, the new leader
    # reloaded, and the next boss opened the council window: the adopted session had lost its features
    w, c = world(session={"loot": False, "rolls": True, "lock": False})
    lee, bob = c["Lee"], c["Bob"]
    want = {"loot": False, "rolls": True, "lock": False}
    w.make_raid([c["Gina"], bob, c["Rita"], lee], leader=bob)
    w.tick(12)
    for how in ({}, {"reload": False}):
        bob.relog(**how)
        w.tick(12)
        for x in c.values():
            assert feats(x) == want, (how, x.name, feats(x))
            assert x.eval("return ns.GroupRules:IsLocked()") is False, (how, x.name)
    # 1.3: the boss brings up the plain roll panel (rolls are on), never the council's
    loot(w, bob, epic(bob))
    assert all(drops(x) == 1 and plain(x) is True for x in c.values()), [(drops(x), plain(x)) for x in c.values()]
    w.assert_no_errors()


def crash(w, cl, offline=5):
    """A game crash: nothing is saved, the character is offline for a moment, then logs back in."""
    cl._shutdown(save=False)
    cl.online = False
    w._sync(roster_changed=True)
    w.tick(offline)
    cl.login()


SPY = ("local C = ns.Comm; local orig = C.Send; C.Send = function(self, m, ...) "
       "if type(m) == 'table' and m.t == 'GSA' then __gsa = (__gsa or 0) + 1; if __lie then m.rf = __lie end end "
       "if type(m) == 'table' and m.t == 'GSQ' then __gsq = (__gsq or 0) + 1 end "
       "return orig(self, m, ...) end")


def answers(c):
    return sum(x.eval("return __gsa or 0") for x in c.values())


def session_id(cl):
    s = cl.eval_py("return ns.GroupRules:GetSession()")
    return s and s["id"]


@case
def a_leader_who_crashed_gets_the_session_back_from_the_raid():
    # nothing saved since Start raid: the leader comes back with no session, the raid still knows it
    want = {"loot": True, "rolls": True, "lock": True}
    w, c = world(session=want)
    lee, rita = c["Lee"], c["Rita"]
    rid = session_id(rita)
    crash(w, lee)
    w.tick(12)
    for x in c.values():
        assert session_id(x) == rid, (x.name, session_id(x))
        assert feats(x) == want, (x.name, feats(x))
        assert x.eval("return ns.GroupRules:IsLocked()") is True, x.name
    assert lee.eval("return ns.RaidLog:GetCurrentID()") == rid             # the raid log records again
    assert any("picked up the raid session" in l for l in printed_since(lee, 0)), printed_since(lee, 0)
    assert on(lee, "rolls") is True and on(lee, "loot") is True
    loot(w, lee, epic(lee))
    assert all(drops(x) == 1 and plain(x) is False for x in c.values()), [(drops(x), plain(x)) for x in c.values()]
    w.assert_no_errors()


@case
def a_crashed_leader_takes_the_settings_the_raid_last_heard():
    # saved (a /reload) with loot on, then Options switched it off, then a crash: the saved copy is out of date
    w, c = world(session={"loot": True, "rolls": True, "lock": False})
    lee = c["Lee"]
    lee.relog()
    w.tick(12)
    want = {"loot": False, "rolls": True, "lock": False}
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }", want)
    assert res["ok"] is True, res
    w.tick(3)
    crash(w, lee)
    raiders = [x for k, x in c.items() if k != "Lee"]
    for _ in range(20):
        w.tick(0.1)
        if session_id(lee):
            break
    # while the leader asks, its client runs on the old saved copy (loot on), but the raid keeps the rules it had:
    # a boss the leader loots now reaches the raiders as a plain roll drop (1.3: rolls are on), not a council one
    assert on(lee, "loot") is True
    loot(w, lee, epic(lee), tick=1)
    for _ in range(10):
        w.tick(0.1)
        for x in raiders:
            assert feats(x) == want, (x.name, feats(x))
    # (the drop can queue a moment behind other guild traffic of a fresh login, e.g. the dungeon board's hello)
    for _ in range(30):
        if all(drops(x) == 1 for x in raiders):
            break
        w.tick(0.1)
        for x in raiders:
            assert feats(x) == want, (x.name, feats(x))
    assert all(drops(x) == 1 and plain(x) is True for x in raiders), [(drops(x), plain(x)) for x in raiders]
    w.tick(10)
    for x in c.values():
        assert feats(x) == want, (x.name, feats(x))
    w.assert_no_errors()


@case
def a_raid_ended_before_the_crash_stays_ended():
    w, c = world(session={"loot": True, "rolls": True, "lock": False})
    lee, rita = c["Lee"], c["Rita"]
    lee.relog()                                 # saved while the session ran
    w.tick(12)
    assert lee.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    crash(w, lee)                               # the saved raid log still has it open
    w.tick(12)
    for x in c.values():
        assert session_id(x) is None, (x.name, session_id(x))
        assert on(x, "loot") is False
    assert lee.eval("return ns.RaidLog:GetCurrentID()") is None
    assert rita.eval("return ns.RaidLog:GetCurrentID()") is None
    assert any("has ended" in l for l in printed_since(lee, 0)), printed_since(lee, 0)
    w.assert_no_errors()


@case
def the_raid_s_answers_need_two_that_agree():
    # four of us: saved with loot on, then Options switched it off, then a crash. Rita lies (loot on): the two
    # honest answers win.
    w, c = world(session={"loot": True, "rolls": True, "lock": False})
    lee, rita = c["Lee"], c["Rita"]
    lee.relog()
    w.tick(12)
    want = {"loot": False, "rolls": True, "lock": False}
    lee.eval_py("return ns.GroupRules:SetSessionFeatures(...)", want)
    w.tick(3)
    for x in c.values():
        x.eval(SPY)
    rita.eval("__lie = 'lr'")
    crash(w, lee)
    w.tick(12)
    assert feats(lee) == want, feats(lee)
    n = answers({k: x for k, x in c.items() if k != "Lee"})
    assert 2 <= n <= 3, n                       # Rita + two others at most: one stays quiet after two agree
    w.assert_no_errors()

    # a raid where Rita is the only other DisasterZone: her answer alone never beats the saved copy
    w = World()
    w.auto_session = False
    lee, rita = Client(w, "Lee", guild_rank=3), Client(w, "Rita", guild_rank=3)
    for x in (lee, rita):
        x.load_addon()
    w.tick(3)
    w.make_raid([lee, rita], leader=lee, extra_members=["Pugone", "Pugtwo"])
    w.tick(8)
    start(lee, want)
    w.tick(3)
    lee.relog()
    w.tick(12)
    rita.eval(SPY)
    rita.eval("__lie = 'lrk'")
    crash(w, lee)
    w.tick(12)
    assert rita.eval("return __gsa or 0") == 1
    assert feats(lee) == want and feats(rita) == want, (feats(lee), feats(rita))
    w.assert_no_errors()


@case
def only_the_raid_leader_is_answered_and_a_reload_changes_nothing():
    w, c = world(session={"loot": False, "rolls": True, "lock": False})
    lee, rita = c["Lee"], c["Rita"]
    for x in c.values():
        x.eval(SPY)
    # a raider asking gets no answer
    rita.eval("ns.Comm:Send({ t = 'GSQ' }, 'RAID', nil, 'alert')")
    w.tick(5)
    assert answers(c) == 0
    # a normal /reload of the leader: asked, answered, nothing to change and nothing printed
    lee.relog()
    w.tick(12)
    assert 2 <= answers(c) <= 3, answers(c)
    assert not any("picked up" in l or "has ended" in l for l in printed_since(lee, 0))
    for x in c.values():
        assert feats(x) == {"loot": False, "rolls": True, "lock": False}, (x.name, feats(x))
    # the answers are not asked again in the same raid
    n = answers(c)
    lee.eval("ns.GroupRules:SetLocked(true)")
    w.tick(5)
    assert answers(c) == n
    w.assert_no_errors()

    # a raid made while everyone is logged in: nothing to ask, the leader's rules go out at once
    w = World()
    w.auto_session = False
    lee, rita = Client(w, "Lee", guild_rank=3), Client(w, "Rita", guild_rank=3)
    for x in (lee, rita):
        x.load_addon()
    w.tick(3)
    lee.eval(SPY)
    w.make_raid([lee, rita], leader=lee)
    w.tick(4)
    assert lee.eval("return __gsq or 0") == 0
    assert rita.eval("return (ns.GroupRules:GetStatus())") == "remote"
    w.assert_no_errors()


@case
def old_leaders_and_malformed_feature_lists():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]

    def gs(rf):
        lee.eval("local rf = ...; ns.Comm:Send({ t = 'GS', v = 900 + (tonumber(__n) or 0), rd = 30, q = 4, dq = 3, "
                 "rs = 'Lee-1', rsAt = GetServerTime() - 5, rf = rf }, 'RAID', nil, 'alert'); __n = (__n or 0) + 1", rf)
        w.tick(2)

    # a session from a raid leader on 1.1 or older names no features: everything runs, as it did then
    gs(None)
    assert on(rita, "loot") is True and on(rita, "rolls") is True
    assert feats(rita) == {"loot": True, "rolls": True, "lock": True}
    # "-" = nothing but the raid log
    gs("-")
    assert on(rita, "loot") is False and on(rita, "rolls") is False
    gs("r")
    assert on(rita, "loot") is False and on(rita, "rolls") is True
    # malformed lists are dropped (the session then counts as one without a list)
    for bad in ("xyz", "", 5, "lrklrklrk"):
        gs(bad)
        assert on(rita, "loot") is True, bad
    w.assert_no_errors()


@case
def a_raider_who_does_not_know_the_rules_yet_takes_an_announced_drop():
    w, c = world(session={"loot": True, "rolls": True, "lock": False})
    bob, rita = c["Bob"], c["Rita"]
    rita.relog()                    # /reload: the rules are asked for again after a few seconds
    w.tick(0.2)
    assert rita.eval("return ns.GroupRules:GetActive()") is None
    assert on(rita, "loot") is False            # not known: nothing of her own is tracked ...
    loot(w, bob, epic(bob), tick=2)
    assert rita.eval("return ns.GroupRules:GetActive()") is None
    assert drops(rita) == 1                     # ... but a drop the raid announces is shown
    w.tick(8)
    assert on(rita, "loot") is True
    w.assert_no_errors()


@case
def the_window_as_a_demo_outside_a_raid():
    w = World()
    c = Client(w, "Alice", guild_rank=0)
    c.load_addon()
    w.tick(3)
    p0 = len(c.chat_frame)
    assert c.eval("return ns.SessionBar:OpenStart()") is False
    assert any("only run in a raid" in l for l in printed_since(c, p0))
    c.slash("/dz demo on")
    w.tick(1)
    c.slash("/dz raid options")
    w.tick(0.2)
    assert c.eval("return %s:IsShown()" % WIN) is True
    assert c.find_text("Start raid (demo)", True, True) and c.find_text("nothing is started", True, True)
    c.click(c.eval("return %s.boxes.loot" % WIN))
    p0 = len(c.chat_frame)
    c.click(c.eval("return %s.startBtn" % WIN))
    said = printed_since(c, p0)
    assert any("rolls on, loot council off, BiS lists open" in l for l in said), said   # (no lock without it)
    assert c.eval("return %s:IsShown()" % WIN) is False
    # demo and test drops are not gated
    c.slash("/dz test")
    w.tick(1)
    assert c.eval("return #ns.Loot:GetHistory()") >= 1
    w.assert_no_errors()


@case
def loot_is_recorded_without_the_loot_council():
    # 1.3: "we manage loot outside the addon and just record the raid": the council and rolls off, the loot handed
    # out still goes into the Loot Log (also before Start raid), with nothing coming up on screen
    w, c = world()
    gina, bob, rita = c["Gina"], c["Bob"], c["Rita"]
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    item = epic(bob)
    w.broadcast_loot_received(rita, item)                  # no raid session yet
    w.tick(8)
    for x in (gina, bob):
        assert logged(x) == [(K("Rita"), item)], (x.name, logged(x))
    assert logged(rita) == []                              # not council: nothing recorded
    assert start(c["Lee"], {"loot": False, "rolls": False, "lock": False})["ok"] is True
    w.tick(3)
    loot(w, bob, item)
    assert all(drops(x) == 0 for x in c.values())          # no drop panel at all
    other = bob.eval("return ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[2].itemID")
    w.broadcast_loot_received(c["Lee"], other)
    w.tick(8)
    for x in (gina, bob):
        assert sorted(logged(x)) == sorted([(K("Rita"), item), (K("Lee"), other)]), (x.name, logged(x))
    w.assert_no_errors()


@case
def a_plain_roll_suggests_the_highest_roll():
    # 1.3: the loot council off, rolls on: BiS lists and votes don't count, the highest roll wins, no tier reason
    w, c = world(session={"loot": False, "rolls": True, "lock": False})
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    item = epic(bob)
    # Rita has it as her BiS main pick: the council would rank her first
    slot = rita.eval("return ns.ItemDB:GetSlotsForItem(...)[1]", item)
    assert rita.eval("return ns.BiS:SetSlot(...)", 1, slot, "main", item)
    rita.eval("ns.BiS:Commit()")
    w.tick(8)
    wanters = bob.eval_py("local o = {}; for _, x in ipairs(ns.Store:GetWanters(...) or {}) do o[#o + 1] = x.key end; "
                          "return o", item)
    assert K("Rita") in wanters, wanters
    sid = bob.eval("return ns.Roll:Start(...).id", item)
    assert sid, sid
    w.tick(1)
    w.player_roll(rita, 20)
    w.player_roll(lee, 90)
    w.tick(1)
    for x in (bob, lee, rita):
        assert x.eval("return ns.Roll:Get(...).plain", sid) is True, x.name
        rows = x.eval_py("return ns.Roll:GetResults(...)", sid)
        top = [r["key"] for r in rows if r.get("suggested")]
        assert top == [K("Lee")], (x.name, rows)
        assert all((r.get("tier") or 4) == 4 for r in rows), rows
    assert bob.eval("return ns.Roll:CanVote(...)", sid) is False
    bob.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    p0 = len(w.chat_log)
    bob.eval("ns.Roll:Award(...)", sid, K("Lee"))
    bob.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(2)
    e = [x for x in bob.eval_py("local o = {}; for _, e in ipairs(ns.Ledger:GetEntries()) do o[#o + 1] = "
                                "{ w = e.w, i = e.i, r = e.r or 'none' } end; return o") if x["i"] == item]
    assert e and e[0]["w"] == K("Lee") and e[0]["r"] == "none", e      # no BiS tier reason
    said = [m["text"] for m in w.chat_log[p0:]]
    assert any("Lee (rolled 90, roll)" in s for s in said), said
    w.assert_no_errors()


PANEL = r"""
  local DP = ns.DropPanel
  local out = { shown = DP.frame ~= nil and DP.frame:IsShown(), blocks = {} }
  if not out.shown then return out end
  out.lock = DP.lockBtn ~= nil and DP.lockBtn:IsShown()
  for _, b in ipairs(DP.blocks) do
    if b:IsShown() then
      local rows = {}
      for _, r in ipairs(b.rows) do
        if r:IsShown() and r.data and r.data.key then
          rows[#rows + 1] = { key = r.data.key, badge = r.badge:GetText() or "", votes = r.votes:IsShown(),
                              roll = r.rollRow and true or false }
        end
      end
      local btns = {}
      for _, btn in ipairs(b.actionButtons) do
        if btn:IsShown() then btns[#btns + 1] = btn:GetText() or "?" end
      end
      local more = {}
      for _, e in ipairs(DP:GetMoreActions(b)) do more[#more + 1] = e.label end
      out.blocks[#out.blocks + 1] = { item = b.itemID, rows = rows, buttons = btns, more = more,
        none = b.none:IsShown() and b.none:GetText() or "" }
    end
  end
  return out"""


@case
def the_plain_roll_panel():
    # 1.3: the loot council off, rolls on: the drop panel lists the items and the rolls, no BiS candidates, badges,
    # votes or lock button; the announcement links the item alone
    w, c = world(session={"loot": False, "rolls": True, "lock": False})
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    item = epic(bob)
    slot = rita.eval("return ns.ItemDB:GetSlotsForItem(...)[1]", item)
    assert rita.eval("return ns.BiS:SetSlot(...)", 1, slot, "main", item)
    rita.eval("ns.BiS:Commit()")
    w.tick(8)
    loot(w, bob, item)
    p = bob.eval_py(PANEL)
    assert p["shown"] and p["lock"] is False, p
    b = p["blocks"][0]
    assert b["rows"] == [] and b["none"] == "", b              # (1.3.1: no "Not rolled yet" line: Roll says it)
    assert "Roll" in b["buttons"] and "Announce" in b["more"], b
    assert bob.eval("return ns.DropPanel:BuildAnnounceLine(...)", item).count("BiS") == 0
    bob.click(bob.eval("return ns.DropPanel.blocks[1].rollBtn"))
    w.tick(1)
    w.player_roll(rita, 30)
    w.player_roll(lee, 80)
    w.tick(1)
    bob.eval("ns.DropPanel:Render()")
    rows = bob.eval_py(PANEL)["blocks"][0]["rows"]
    assert [r["key"] for r in rows] == [K("Lee"), K("Rita")], rows          # by roll, not by BiS list
    assert all(r["roll"] and r["badge"] == "" and r["votes"] is False for r in rows), rows
    # the same raid with the loot council: Rita's BiS row is back (a new boss)
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                      {"loot": True, "rolls": True, "lock": False})
    assert res["ok"] is True, res
    w.tick(3)
    bob.open_loot([(item, 4)], source_guid="Creature-0-1-2-3-15691-000ABD")
    w.tick(3)
    bob.eval("ns.DropPanel:Page(1)")       # (the panel stays on the drop whose roll is still open)
    b = bob.eval_py(PANEL)["blocks"][0]
    assert [r["key"] for r in b["rows"]] == [K("Rita")] and b["rows"][0]["badge"] != "", b
    w.assert_no_errors()


@case
def parties_are_not_affected():
    w = World()
    w.auto_session = False
    a = Client(w, "Alice", guild_rank=0)
    b = Client(w, "Bob", guild_rank=3, class_file="MAGE")
    for x in (a, b):
        x.load_addon()
    w.tick(3)
    w.make_party([a, b], leader=a)
    w.tick(5)
    assert on(a, "loot") is True and on(a, "rolls") is True and feats(a) is None
    res = a.eval_py("local ok, e = ns.GroupRules:SetSession(true); return { ok = ok, e = e }")
    assert res["ok"] is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
