"""The release plan (Core/FeedbackPlan.lua): the developer puts the guild's feedback (and own items) in releases with a
size; officers see the plan read-only; the guild sees Coming next (shown releases, guild items only); the dev kit's
file (Core/DevPlan.lua) merges with the saved plan, the newer edit winning.

Run: luaenv\\Scripts\\python.exe tests\\feedback\\test_feedback_plan.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

REALM = "Thunderstrike"
F = "ns.Feedback"
P = "ns.FeedbackPlan"


def K(name):
    return "%s-%s" % (name, REALM)


def standard():
    """Gina the GM, Olaf an officer, Tsumil the developer (a plain member), Alfa and Bert raiders; settled."""
    w = World()
    c = {}
    for name, cls, rank in [("Gina", "PALADIN", 0), ("Olaf", "WARRIOR", 1), ("Tsumil", "PALADIN", 3),
                            ("Alfa", "MAGE", 3), ("Bert", "ROGUE", 3)]:
        c[name] = Client(w, name, class_file=cls, guild_rank=rank)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.tick(60, step=0.25)
    return w, c


def submit(cl, kind, text):
    return cl.eval("local kind, text = ...; local id, err = %s:Submit(kind, text); return id or err" % F, kind, text)


def ok(cl, lua, *args):
    r = cl.eval_py("local ok, err = %s; return { ok = ok and true or false, err = err or false }" % lua, *args)
    return r


def columns(cl, rl=None):
    return cl.eval_py("local out = {}; for i, c in ipairs(%s:Cards(...)) do out[i] = c.key end; return out" % P, rl)


def coming(cl):
    return cl.eval_py("local out = {}; for i, r in ipairs(%s:ComingNext()) do local ids = {}; "
                      "for j, it in ipairs(r.items) do ids[j] = it.id end; out[i] = { v = r.v, th = r.th or false, "
                      "ids = ids } end; return out" % P)


def setup_plan(w, c):
    """Two guild items, a 1.9.1 the guild sees, a 1.9.2 it doesn't, a dev item; returns (alfa, bert) ids."""
    a = submit(c["Alfa"], "idea", "Auto-sell junk at vendors. And repair.")
    b = submit(c["Bert"], "bug", "Execute shows before it is learned.")
    w.tick(10, step=0.25)
    t = c["Tsumil"]
    assert ok(t, P + ":SetRelease('1.9.1', { th = 'Quality of life', bg = 8, pub = true })")["ok"]
    assert ok(t, P + ":SetRelease('1.9.2', { th = 'Secret stuff', bg = 24 })")["ok"]
    assert ok(t, P + ":Place(..., '1.9.1')", a)["ok"]
    assert ok(t, P + ":SetSize(..., 'M')", a)["ok"]
    assert ok(t, P + ":Place(..., '1.9.2')", b)["ok"]
    d = t.eval("return %s:AddDevItem('Boss mods: Karazhan', 'idea', 'XL', '1.9.1')" % P)
    assert d == "D-1", d
    w.tick(10, step=0.25)
    return a, b


@case
def the_developer_plans_officers_see_it_and_the_guild_sees_coming_next():
    w, c = standard()
    a, b = setup_plan(w, c)
    t = c["Tsumil"]
    assert sorted(columns(t, "1.9.1")) == sorted([a, "D-1"]), columns(t, "1.9.1")
    assert columns(t, "1.9.2") == [b]
    assert t.eval("return (%s:Load('1.9.1'))" % P) == 15        # M 3 + XL 12
    # placing an item planned it: its author sees Planned
    assert c["Alfa"].eval("return %s:Get(...).state" % F, a) == "planned"
    # the officer holds the plan, dev item included
    w.tick(10, step=0.25)
    assert sorted(columns(c["Olaf"], "1.9.1")) == sorted([a, "D-1"]), columns(c["Olaf"], "1.9.1")
    # a raider sees only the shown release and only the guild's item; no plan at all
    got = coming(c["Bert"])
    assert got == [{"v": "1.9.1", "th": "Quality of life", "ids": [a]}], got
    assert c["Bert"].eval("return %s:CanSee()" % P) is False
    assert c["Bert"].eval("return (%s:PlannedFor(...))" % P, a) == "1.9.1"
    assert c["Bert"].eval("return (%s:PlannedFor(...))" % P, b) is None
    w.assert_no_errors()


@case
def officers_and_members_cannot_change_the_plan_or_fake_it():
    w, c = standard()
    a, _ = setup_plan(w, c)
    r = ok(c["Olaf"], P + ":Place(..., nil)", a)
    assert not r["ok"] and "developer" in r["err"], r
    # a raider's made-up Coming next and plan are refused
    alfa = c["Alfa"]
    alfa.eval("ns.Comm:Send({ t = 'FBC', c = { rev = 2000000000, l = { { v = '9.9.9', th = 'Fake', n = {} } } } }, "
              "'GUILD', nil, 'fb')")
    alfa.eval("ns.Comm:Send({ t = 'FBP', p = { rev = 2000000000, rel = {}, it = {} } }, 'WHISPER', ...)", K("Olaf"))
    w.tick(5, step=0.25)
    assert [x["v"] for x in coming(c["Bert"])] == ["1.9.1"]
    assert c["Olaf"].eval("return %s:Release('1.9.1') ~= nil" % P) is True
    w.assert_no_errors()


@case
def a_member_who_logs_in_later_asks_staff_for_coming_next():
    w, c = standard()
    a, b = setup_plan(w, c)
    c["Bert"].logout()
    w.tick(5)
    # while Bert is away, his bug joins the release the guild sees
    assert ok(c["Tsumil"], P + ":Place(..., '1.9.1')", b)["ok"]
    w.tick(10, step=0.25)
    c["Bert"].login()
    w.tick(90, step=0.25)
    got = coming(c["Bert"])
    assert got and sorted(got[0]["ids"]) == sorted([a, b]), got
    # an officer who was away gets the whole plan
    c["Olaf"].logout()
    w.tick(5)
    assert ok(c["Tsumil"], P + ":SetNote(..., 'hook MERCHANT_SHOW')", a)["ok"]
    w.tick(10, step=0.25)
    c["Olaf"].login()
    w.tick(90, step=0.25)
    assert c["Olaf"].eval("return %s:Entry(...).nt" % P, a) == "hook MERCHANT_SHOW"
    w.assert_no_errors()


@case
def the_dev_kit_file_merges_and_the_newer_edit_wins():
    w, c = standard()
    a, b = setup_plan(w, c)
    t = c["Tsumil"]
    gk = t.eval("return ns.Util.GuildKey()")
    now = t.eval("return ns.Util.Now()")
    # the file: a newer size for a, an older place for b (the game's newer one stays), a new release and dev item
    t.eval("""local gk, now, a, b = ...
        DisasterZoneDevPlan = { gk = gk, p = { rev = now + 50, rel = {
            ['1.9.3'] = { th = 'From the dev kit', bg = 8, u = now + 50 } }, it = {
            [a] = { rl = '1.9.1', sz = 'S', u = now + 50 },
            [b] = { rl = 'later', u = 5 },
            ['D-7'] = { tt = 'Written by Claude', kd = 'chore', sz = 'S', rl = '1.9.3', at = now, u = now + 50 } } } }""",
           gk, now, a, b)
    assert t.eval("return %s:TakeFile()" % P) is True
    assert t.eval("return %s:Entry(...).sz" % P, a) == "S"
    assert t.eval("return %s:Entry(...).rl" % P, b) == "1.9.2"
    assert columns(t, "1.9.3") == ["D-7"]
    # a file for another guild is left alone
    t.eval("DisasterZoneDevPlan.gk = 'Someone Else-Nowhere'; DisasterZoneDevPlan.p.rev = DisasterZoneDevPlan.p.rev + 1")
    assert t.eval("return %s:TakeFile()" % P) is False
    w.assert_no_errors()


@case
def release_check_and_marking_a_release_released():
    w, c = standard()
    a, b = setup_plan(w, c)
    t = c["Tsumil"]
    no = t.eval("return %s:Get(...).no" % F, a)
    # a's number in this release's changelog: shipped; the dev item not yet
    t.eval("table.insert(ns.CHANGELOG, 1, { version = '1.9.1', sections = { { lines = { "
           "{ 'Junk sells itself', fb = { ... } } } } } })", no)
    chk = t.eval_py("local c = %s:Check('1.9.1'); return { done = c.done, total = c.total, draft = #c.draft }" % P)
    assert chk == {"done": 1, "total": 2, "draft": 1}, chk
    assert ok(t, P + ":MarkReleased('1.9.1', '1.9.2')")["ok"]
    assert columns(t, "1.9.2") == sorted([b, "D-1"]) or sorted(columns(t, "1.9.2")) == sorted([b, "D-1"])
    assert t.eval("return %s:Release('1.9.1').done ~= nil" % P) is True
    assert [r["v"] for r in t.eval_py("return %s:Releases()" % P)] == ["1.9.2"]
    w.assert_no_errors()


@case
def demo_mode_has_a_plan_and_never_sends_it():
    w, c = standard()
    alfa = c["Alfa"]
    alfa.slash("/dz demo on")
    w.tick(1)
    start = len(w.addon_log)
    rels = alfa.eval_py("return %s:Releases()" % P)
    assert len(rels) == 2, rels
    assert len(alfa.eval_py("return %s:Cards(nil)" % P)) >= 1
    key = alfa.eval("return %s:AddDevItem('Try it', 'idea', 'S', ...)" % P, rels[0]["v"])
    assert key and key.startswith("D-"), key
    w.tick(10, step=0.25)
    sent = [e for e in w.addon_log[start:] if e["prefix"] == "CDLb" and ("FBP" in str(e) or "FBC" in str(e))]
    assert not sent, sent
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
