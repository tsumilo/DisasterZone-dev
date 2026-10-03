"""Raid features (1.2): in a raid, loot distribution and rolls are off until the raid leader starts a raid session,
and the session says which of them it runs.

Covers: no session = no drops, no rolls (for the leader and for raiders); Start raid opening the window from the
session bar and from the Raids tab; starting with everything, without loot distribution, without rolls, without the BiS
lock; changing the features of a running session (Options); the features following the session to a new raid
leader and surviving the leader's /reload; ending the raid switching everything off again; a session from a raid
leader on an older version (no feature list) running everything; malformed feature lists; a raider who doesn't know
the rules yet taking an announced drop; the window as a demo outside a raid; /dz raid start | options; dungeon mode
and /dz test staying as they were.

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
    assert any("Loot distribution is off" in l for l in printed_since(bob, p0)), printed_since(bob, p0)
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
    loot(w, bob, item)
    assert all(drops(x) == 0 for x in c.values())
    assert bob.eval("return ns.Roll:CanStart()") is True
    assert bob.eval("return ns.Roll:Start(...) ~= nil", item) is True
    w.tick(2)
    assert rita.eval("return ns.Roll:GetActive() ~= nil") is True
    # Options: the leader switches loot on and rolls off during the raid
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                      {"loot": True, "rolls": False, "lock": True})
    assert res["ok"] is True, res
    w.tick(3)
    for x in c.values():
        assert feats(x) == {"loot": True, "rolls": False, "lock": True}, (x.name, feats(x))
        assert x.eval("return ns.GroupRules:IsLocked()") is True
    assert bob.eval("return ns.Roll:CanStart()") is False
    loot(w, c["Gina"], epic(bob) + 0)
    assert all(drops(x) == 1 for x in c.values()), [drops(x) for x in c.values()]
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
    assert lee.find_text("loot and rolls are off until you start", True, True)
    # the bar's Start raid asks first
    lee.click(lee.eval("return %s.button" % bar))
    w.tick(0.2)
    assert lee.eval("return %s:IsShown()" % WIN) is True and lee.eval("return ns.GroupRules:GetSession()") is None
    assert lee.find_text("Loot distribution", True, True) and lee.find_text("Lock everyone's BiS lists", True, True)
    for key in ("loot", "rolls", "lock"):
        assert lee.eval("return %s.boxes[...]:GetChecked()" % WIN, key) is True, key
    # untick rolls, start
    lee.click(lee.eval("return %s.boxes.rolls" % WIN))
    lee.click(lee.eval("return %s.startBtn" % WIN))
    w.tick(3)
    assert lee.eval("return %s:IsShown()" % WIN) is False
    for x in c.values():
        assert feats(x) == {"loot": True, "rolls": False, "lock": True}, (x.name, feats(x))
    assert lee.find_text("rolls off", True, True) and rita.find_text("rolls off", True, True)
    # Options (the leader only): the window again, with what runs now; Apply changes it
    assert lee.eval("return %s.options:IsShown()" % bar) is True and rita.eval("return %s.options:IsShown()" % bar) is False
    lee.click(lee.eval("return %s.options" % bar))
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
    assert any("rolls on, loot distribution off, BiS lists locked" in l for l in said), said
    assert c.eval("return %s:IsShown()" % WIN) is False
    # demo and test drops are not gated
    c.slash("/dz test")
    w.tick(1)
    assert c.eval("return #ns.Loot:GetHistory()") >= 1
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
