"""The Discord bridge, addon side (Core/Bridge.lua): records the host's launcher writes into DZBridgeInbox are applied
once, marked in DisasterZoneBridgeDB.applied (the launcher drops them from its queue after the next save), unknown
types and failing handlers are marked not ok, old marks are pruned, and /dz bridge demo saves nothing.

Run: luaenv\\Scripts\\python.exe tests\\bridge\\test_bridge.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from _common import case, run_all, solo, no_errors, printed_since  # noqa: E402
import rp_common as rp  # noqa: E402

CHAN_G, CHAN_T = "123456789012345678", "223456789012345678"

INBOX = """
DZBridgeInbox = { v = 1, written = 1000, records = {
  { id = "a1", type = "test", by = "Tsumi", body = { text = "hello" } },
  { id = "a2", type = "future", by = "Tsumi" },
} }
"""


def login(c):
    """Run the module's login step again (the inbox is set after the client booted)."""
    c.eval("ns.Bridge:OnLogin()")


@case
def applies_each_record_once():
    w, c = solo()
    c.eval(INBOX)
    n0 = len(c.chat_frame)
    login(c)
    lines = printed_since(c, n0)
    assert any("Discord test from Tsumi: hello" in l for l in lines), lines
    assert any("Loaded 2 updates from Discord" in l for l in lines), lines
    marks = c.eval_py("return DisasterZoneBridgeDB.applied")
    assert marks["a1"]["ok"] is True, marks
    assert marks["a2"]["ok"] is False and "unknown type" in marks["a2"]["why"], marks
    n1 = len(c.chat_frame)
    login(c)                                   # a second reload: nothing new
    assert not any("Discord" in l for l in printed_since(c, n1))
    no_errors(w)


@case
def failing_handler_is_marked_not_taken():
    w, c = solo()
    c.eval("ns.Bridge:RegisterType('boom', function() error('broken') end)")
    c.eval("DZBridgeInbox = { records = { { id = 'b1', type = 'boom' } } }")
    login(c)
    m = c.eval_py("return DisasterZoneBridgeDB.applied.b1")
    assert m["ok"] is False and "broken" in m["why"], m
    no_errors(w)


@case
def old_marks_leave_once_their_record_is_gone():
    w, c = solo()
    c.eval("""DisasterZoneBridgeDB = { applied = {
      gone = { t = time() - 30 * 86400, ok = true },
      kept = { t = time() - 30 * 86400, ok = true },
      fresh = { t = time(), ok = true } } }
      DZBridgeInbox = { records = { { id = 'kept', type = 'test' } } }""")
    login(c)
    marks = c.eval_py("return DisasterZoneBridgeDB.applied")
    assert "gone" not in marks and "kept" in marks and "fresh" in marks, marks
    no_errors(w)


@case
def no_inbox_means_not_the_host():
    w, c = solo()
    login(c)
    assert c.eval("return DisasterZoneBridgeDB == nil")
    n0 = len(c.chat_frame)
    c.slash("/dz bridge")
    assert any("not set up on this PC" in l for l in printed_since(c, n0)), printed_since(c, n0)
    no_errors(w)


@case
def demo_saves_nothing():
    w, c = solo()
    n0 = len(c.chat_frame)
    c.slash("/dz bridge demo")
    lines = printed_since(c, n0)
    assert any("Discord test from Demo" in l for l in lines), lines
    assert any("refused: unknown type nope" in l for l in lines), lines
    assert c.eval("return DisasterZoneBridgeDB == nil")
    no_errors(w)


@case
def gm_sets_discord_and_the_guild_gets_it():
    w, c = rp.world()
    gina, lee = c["Gina"], c["Lee"]
    tid = rp.team(c["Bob"], "Main", ["Lee", "Rita"])
    w.tick(3)
    res = gina.eval_py("local h, g, t, c = ...; local ok, e = ns.Guild:SetDiscord({ host = h, guild = g, teams = { [t] = c } });"
                       " return { ok = ok, e = e }", rp.K("Gina"), CHAN_G, tid, CHAN_T)
    assert res["ok"] is True, res
    w.tick(3)
    d = lee.eval_py("return ns.Guild:GetDiscord()")
    assert d["host"] == rp.K("Gina") and d["guild"] == CHAN_G and d["teams"][tid] == CHAN_T, d
    assert lee.eval("return ns.Guild:IsDiscordHost(...)", rp.K("Gina")) is True
    assert lee.eval("return ns.Guild:IsDiscordHost(...)", rp.K("Lee")) is False
    bad = lee.eval_py("local ok, e = ns.Guild:SetDiscord({ host = ... }); return { ok = ok, e = e }", rp.K("Lee"))
    assert bad["ok"] is False and "Guild Master" in bad["e"], bad
    bad = gina.eval_py("local ok, e = ns.Guild:SetDiscord({ guild = 'general' }); return { ok = ok, e = e }")
    assert bad["ok"] is False, bad
    no_errors(w)


@case
def snapshot_lists_upcoming_raids_with_signups():
    w, c = rp.world()
    gina, bob, lee = c["Gina"], c["Bob"], c["Lee"]
    tid = rp.team(bob, "Main", ["Lee", "Rita"])
    t0 = rp.now(bob) + 2 * rp.DAY
    occ = rp.create(bob, i="kara", t=t0, tm=[tid], no="Bring pots")
    hidden = rp.create(bob, i="gruul", t=t0 + 3600, pv=True)
    w.tick(3)
    assert rp.signup(lee, occ, "A", 3)["ok"] is True
    w.tick(3)
    gina.eval("DZBridgeInbox = { records = {}, channels = { { id = '123456789012345678', name = 'raids' } } }")
    login(gina)
    assert gina.eval_py("return ns.Bridge:GetChannels()") == [{"id": CHAN_G, "name": "raids"}]
    gina.fire("PLAYER_LOGOUT")
    snap = gina.eval_py("return DisasterZoneBridgeDB.snap")
    ids = [r["id"] for r in snap["raids"]]
    assert occ in ids and hidden not in ids, ids
    r = [x for x in snap["raids"] if x["id"] == occ][0]
    assert r["t"] == t0 and r["name"] == "Karazhan" and r["note"] == "Bring pots" and r["teams"] == [tid], r
    assert r["signups"] == [{"key": rp.K("Lee"), "st": "accept", "class": "WARRIOR", "spec": "Protection",
                             "role": "tank", "at": r["signups"][0]["at"]}], r["signups"]
    assert snap["teams"][tid] == "Main"
    no_errors(w)


def discord_world():
    w, c = rp.world()
    gina = c["Gina"]
    res = gina.eval_py("local ok, e = ns.Guild:SetDiscord({ host = ... }); return { ok = ok, e = e }", rp.K("Gina"))
    assert res["ok"] is True, res
    w.tick(3)
    return w, c


@case
def discord_signup_from_the_host_reaches_the_guild():
    w, c = discord_world()
    gina, bob, lee, rita = c["Gina"], c["Bob"], c["Lee"], c["Rita"]
    occ = rp.create(bob, i="kara", t=rp.now(bob) + 2 * rp.DAY)
    w.tick(3)
    gina.eval("local o, k = ...; DZBridgeInbox = { records = { { id = 'dc_1', type = 'signup', by = 'lee', body = { raid = o, key = k, st = 'A', sp = 3 } } } }",
              occ, rp.K("Lee"))
    login(gina)
    w.tick(3)
    m1 = gina.eval_py("return DisasterZoneBridgeDB.applied.dc_1")
    assert m1["ok"] is True, m1
    su = rp.signups(rita, occ)[rp.K("Lee")]
    assert su["st"] == "A" and su["sp"] == 3 and su["dc"] == 1, su
    # a raid it can't take: marked not ok with the reason
    rp.call(bob, "CancelRaid", occ, "one")
    w.tick(3)
    gina.eval("local o, k = ...; DZBridgeInbox = { records = { { id = 'dc_2', type = 'signup', body = { raid = o, key = k, st = 'T' } } } }",
              occ, rp.K("Rita"))
    login(gina)
    m = gina.eval_py("return DisasterZoneBridgeDB.applied.dc_2")
    assert m["ok"] is False and "cancelled" in m["why"], m
    no_errors(w)


@case
def only_the_host_signs_up_others():
    w, c = discord_world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    occ = rp.create(bob, i="kara", t=rp.now(bob) + 2 * rp.DAY)
    w.tick(3)
    res = lee.eval_py("local ok, e = ns.RaidPlan:SignUpFor(...); return { ok = ok, e = e }", occ, rp.K("Rita"), "A")
    assert res["ok"] is False and "host" in res["e"], res
    # a forged RPH from a non-host is ignored
    lee.eval("local o, k = ...; ns.Comm:Send({ t = 'RPH', l = { { o = o, k = k, s = { st = 'A', rev = GetServerTime(), c = 'PRIEST' } } } }, 'GUILD')",
             occ, rp.K("Rita"))
    w.tick(3)
    assert rp.K("Rita") not in rp.signups(bob, occ)
    no_errors(w)


@case
def link_code_reaches_the_host():
    w, c = discord_world()
    gina, lee = c["Gina"], c["Lee"]
    n0 = len(lee.chat_frame)
    lee.slash("/dz link abc123")
    w.tick(3)
    claims = gina.eval_py("return DisasterZoneBridgeDB and DisasterZoneBridgeDB.claims")
    assert claims["ABC123"]["k"] == rp.K("Lee"), claims
    lines = printed_since(lee, n0)
    assert any("Discord host got your code" in l for l in lines), lines
    assert lee.eval("return DisasterZoneBridgeDB.link == nil")
    # the snapshot lists a linked character's class and specs
    gina.eval("DZBridgeInbox = { records = {}, linked = { ... } }", rp.K("Lee"))
    login(gina)
    gina.fire("PLAYER_LOGOUT")
    ch = gina.eval_py("return DisasterZoneBridgeDB.snap.chars")[rp.K("Lee")]
    assert ch["class"] == "WARRIOR" and ch["specs"] == ["Arms", "Fury", "Protection"], ch
    no_errors(w)


if __name__ == "__main__":
    run_all()
