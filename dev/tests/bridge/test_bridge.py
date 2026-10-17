"""The Discord bridge, addon side (Core/Bridge.lua): the records the bot's server signs reach the game through the
inbox every linked launcher writes (DZBridge). They are checked against the bridge key, applied once by whoever loads
them first, marked in DisasterZoneBridgeDB.applied (the server drops them after the next upload) and relayed to the
guild with their signature (DZR), where every online game checks and applies them too. Unsigned or altered records do
nothing; unknown types and failing handlers are marked not ok; a record its taker can't apply (a guest needs a raid
manager, a list kept for a member without the addon needs the council) is left for someone else.

Run: luaenv\\Scripts\\python.exe tests\\bridge\\test_bridge.py [-k name]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "raidplan"))
sys.path.insert(0, os.path.join(os.path.dirname(TESTS), "tools"))

from _common import case, run_all, solo, no_errors, printed_since  # noqa: E402
import rp_common as rp  # noqa: E402
import patchlib  # noqa: E402

CHAN_G, CHAN_T = "123456789012345678", "223456789012345678"

# ---------------------------------------------------------------------------------------------------------------
# Signing like the bot's server (launcher/proto: Record::message + wots, the same scheme as patchlib)
# ---------------------------------------------------------------------------------------------------------------

_KEY = {}
_LEAF = [0]


def key():
    if not _KEY:
        _KEY.update(patchlib.keygen(height=6, secret=bytes(range(32)), seed=bytes(range(16))))
    return _KEY


def _s(x):
    b = x.encode("utf-8")
    return b"s%d:" % len(b) + b


def _v(v):
    if v is None:
        return b"n"
    if isinstance(v, bool):
        return b"t" if v else b"f"
    if isinstance(v, int):
        return b"i%d;" % v
    if isinstance(v, str):
        return _s(v)
    assert isinstance(v, dict), v
    out = b"{"
    for k in sorted((k for k in v if v[k] is not None), key=lambda k: k.encode("utf-8")):
        out += _s(k) + _v(v[k])
    return out + b"}"


def message(r):
    return b"DZB1" + _s(r["id"]) + _s(r["type"]) + b"i%d;" % r["at"] + _s(r["by"]) + _s(r.get("discord", "")) + _v(r.get("body"))


def signed(rid, kind, body=None, by="Tsumi", at=1792000000, discord="42"):
    r = {"id": rid, "type": kind, "at": at, "by": by, "body": body or {}, "discord": discord}
    _LEAF[0] += 1
    r["sig"] = patchlib.sign(key(), _LEAF[0] % 64, message(r)).hex()
    return r


def lua(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "{ " + ", ".join(lua(x) for x in v) + " }"
    return "{ " + ", ".join("[%s] = %s" % (json.dumps(k), lua(x)) for k, x in v.items()) + " }"


def use_key(cl):
    k = key()
    cl.eval("local s, r = ...; ns.BridgeKey = { seed = s, root = r, h = 6 }", k["seed"], k["root"])


def inbox(cl, records, channels=None, user="Tsumi"):
    """This PC's launcher wrote these records; the game loads them (login) and checks them over a few frames."""
    use_key(cl)
    cl.eval("DZBridge = { v = 2, written = 1000, user = %s, records = %s, channels = %s }"
            % (json.dumps(user), lua(records), lua(channels or [])))
    cl.eval("ns.Bridge:OnLogin()")


def relay(cl, r, target=None):
    """A member sends this record on (DZR), its signature as the wire carries it (binary)."""
    cl.eval("local r = %s; r.sig = ns.Sha256.FromHex(r.sig) or r.sig; ns.Comm:Send({ t = 'DZR', r = r }, %s, %s, 'data')"
            % (lua(r), json.dumps("WHISPER" if target else "GUILD"), json.dumps(target) if target else "nil"))


def settle(w, s=3):
    w.tick(s)


# ---------------------------------------------------------------------------------------------------------------

@case
def lua_signs_the_same_bytes_as_the_bot():
    """The Rust test vector (launcher/proto lib.rs message_is_canonical) from the Lua side."""
    w, c = solo()
    got = c.eval("return ns.Bridge.Message({ id = 'dc_1', type = 'signup', at = 1791900000, by = 'Tsumi', discord = '42',"
                 " body = { st = 'A', raid = 'r1', sp = 3, late = true, nest = { b = 1, a = 'x' } } })")
    assert got == "DZB1s4:dc_1s6:signupi1791900000;s5:Tsumis2:42{s4:latets4:nest{s1:as1:xs1:bi1;}s4:raids2:r1s2:spi3;s2:sts1:A}", got
    assert c.eval("return ns.Bridge.Message({ id = 'a', type = 'b', at = 1.5, by = 'c' })") is None
    assert c.eval("return ns.Bridge.Message({ id = 'a', type = 'b', at = 1, by = 'c', body = { 1, 2 } })") is None
    # and the Python signer's (this file's) bytes match the Lua ones
    r = signed("x1", "test", {"text": "Élise | hi"})
    assert c.eval("return ns.Bridge.Message(%s)" % lua(r)) == message(r).decode("utf-8")
    no_errors(w)


@case
def applies_each_signed_record_once():
    w, c = solo()
    n0 = len(c.chat_frame)
    inbox(c, [signed("a1", "test", {"text": "hello"}), signed("a2", "future")])
    settle(w)
    lines = printed_since(c, n0)
    assert any("Discord test from Tsumi: hello" in l for l in lines), lines
    assert any("Loaded 2 updates from Discord" in l for l in lines), lines
    marks = c.eval_py("return DisasterZoneBridgeDB.applied")
    assert marks["a1"]["ok"] is True, marks
    assert marks["a2"]["ok"] is False and "unknown type" in marks["a2"]["why"], marks
    n1 = len(c.chat_frame)
    c.eval("ns.Bridge:OnLogin()")             # a second reload: nothing new
    settle(w)
    assert not any("Discord" in l for l in printed_since(c, n1))
    no_errors(w)


@case
def unsigned_or_altered_records_do_nothing():
    w, c = solo()
    good = signed("ok1", "test", {"text": "real"})
    altered = signed("bad1", "test", {"text": "real"})
    altered["body"]["text"] = "forged"
    unsigned = {"id": "bad2", "type": "test", "at": 1, "by": "x", "body": {"text": "forged"}}
    other_key = signed("bad3", "test", {"text": "forged"})
    other_key["sig"] = patchlib.sign(patchlib.keygen(height=6, secret=b"\x01" * 32, seed=b"\x02" * 16), 1,
                                     message(other_key)).hex()
    n0 = len(c.chat_frame)
    inbox(c, [altered, unsigned, other_key, good])
    settle(w)
    lines = printed_since(c, n0)
    assert not any("forged" in l for l in lines), lines
    assert any("Discord test from Tsumi: real" in l for l in lines), lines
    marks = c.eval_py("return DisasterZoneBridgeDB.applied")
    # (not marked either: a key mismatch must not make the bot drop the guild's changes as refused)
    assert set(marks) == {"ok1"}, marks
    no_errors(w)


@case
def failing_handler_is_marked_not_taken():
    w, c = solo()
    c.eval("ns.Bridge:RegisterType('boom', function() error('broken') end)")
    inbox(c, [signed("b1", "boom")])
    settle(w)
    m = c.eval_py("return DisasterZoneBridgeDB.applied.b1")
    assert m["ok"] is False and "broken" in m["why"], m
    no_errors(w)


@case
def old_marks_leave_once_their_record_is_gone():
    w, c = solo()
    c.eval("""DisasterZoneBridgeDB = { applied = {
      gone = { t = time() - 30 * 86400, ok = true },
      kept = { t = time() - 30 * 86400, ok = true },
      fresh = { t = time(), ok = true } } }""")
    inbox(c, [signed("kept", "test")])
    settle(w)
    marks = c.eval_py("return DisasterZoneBridgeDB.applied")
    assert "gone" not in marks and "kept" in marks and "fresh" in marks, marks
    no_errors(w)


@case
def no_inbox_means_no_launcher():
    w, c = solo()
    c.eval("ns.Bridge:OnLogin()")
    assert c.eval("return DisasterZoneBridgeDB == nil")
    n0 = len(c.chat_frame)
    c.slash("/dz bridge")
    assert any("no launcher linked" in l for l in printed_since(c, n0)), printed_since(c, n0)
    no_errors(w)


@case
def demo_saves_nothing():
    w, c = solo()
    n0 = len(c.chat_frame)
    c.slash("/dz bridge demo")
    settle(w)
    lines = printed_since(c, n0)
    assert any("Discord test from Demo" in l for l in lines), lines
    assert any("refused: unknown type nope" in l for l in lines), lines
    assert any("unsigned record ignored" in l for l in lines), lines
    assert c.eval("return DisasterZoneBridgeDB == nil")
    no_errors(w)


@case
def gm_sets_discord_and_the_guild_gets_it():
    w, c = rp.world()
    gina, lee = c["Gina"], c["Lee"]
    tid = rp.team(c["Bob"], "Main", ["Lee", "Rita"])
    w.tick(3)
    res = gina.eval_py("local g, t, c = ...; local ok, e = ns.Guild:SetDiscord({ guild = g, teams = { [t] = c } });"
                       " return { ok = ok, e = e }", CHAN_G, tid, CHAN_T)
    assert res["ok"] is True, res
    w.tick(3)
    d = lee.eval_py("return ns.Guild:GetDiscord()")
    assert d["guild"] == CHAN_G and d["teams"][tid] == CHAN_T, d
    bad = lee.eval_py("local ok, e = ns.Guild:SetDiscord({ guild = ... }); return { ok = ok, e = e }", CHAN_T)
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
    inbox(gina, [], channels=[{"id": CHAN_G, "name": "raids"}])
    assert gina.eval_py("return ns.Bridge:GetChannels()") == [{"id": CHAN_G, "name": "raids"}]
    w.tick(5)
    gina.fire("PLAYER_LOGOUT")
    snap = gina.eval_py("return DisasterZoneBridgeDB.snap")
    assert snap["up"] >= 5 and snap["guild"], snap
    ids = [r["id"] for r in snap["raids"]]
    assert occ in ids and hidden not in ids, ids
    r = [x for x in snap["raids"] if x["id"] == occ][0]
    assert r["t"] == t0 and r["name"] == "Karazhan" and r["note"] == "Bring pots" and r["teams"] == [tid], r
    su = r["signups"][0]
    assert su["key"] == rp.K("Lee") and su["st"] == "accept" and su["class"] == "WARRIOR" and su["spec"] == "Protection", su
    assert su["role"] == "tank" and su["rev"] >= 1 and su["at"], su
    assert snap["teams"][tid] == "Main"
    # (the launcher's Home gets the same raids, in DisasterZoneDB)
    home = gina.eval_py("return DisasterZoneDB.launcher")
    assert [r["id"] for r in home["raids"]] == ids and home["me"] == rp.K("Gina"), home
    no_errors(w)


@case
def the_launchers_home_is_written_on_every_pc():
    w, c = rp.world()
    bob, rita = c["Bob"], c["Rita"]
    tid = rp.team(bob, "Main", ["Lee", "Rita"])
    t0 = rp.now(bob) + rp.DAY
    occ = rp.create(bob, i="ssc", t=t0, tm=[tid])
    hidden = rp.create(bob, i="gruul", t=t0 + 3600, pv=True)
    w.tick(3)
    assert rp.signup(rita, occ, "A", 1)["ok"] is True
    w.tick(3)
    rita.eval("ns.Bridge:OnLogin()")
    rita.fire("PLAYER_LOGOUT")
    home = rita.eval_py("return DisasterZoneDB.launcher")
    assert home["me"] == rp.K("Rita") and home["at"], home
    ids = [r["id"] for r in home["raids"]]
    assert occ in ids and hidden not in ids, ids
    r = [x for x in home["raids"] if x["id"] == occ][0]
    assert r["t"] == t0 and r["name"] == "Serpentshrine Cavern" and r["inst"] == "ssc", r
    assert r["signups"][0]["key"] == rp.K("Rita") and r["signups"][0]["st"] == "accept", r
    # (no launcher linked here: no snapshot for the bot)
    assert rita.eval("return DisasterZoneBridgeDB == nil or DisasterZoneBridgeDB.snap == nil")
    no_errors(w)


@case
def a_snapshot_is_written_only_where_a_launcher_syncs():
    w, c = rp.world()
    rita = c["Rita"]
    rita.eval("ns.Bridge:OnLogin()")
    rita.fire("PLAYER_LOGOUT")
    assert rita.eval("return DisasterZoneBridgeDB == nil or DisasterZoneBridgeDB.snap == nil")
    no_errors(w)


@case
def discord_signup_taken_by_any_member_reaches_the_guild():
    w, c = rp.world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    occ = rp.create(bob, i="kara", t=rp.now(bob) + 2 * rp.DAY)
    w.tick(3)
    for cl in c.values():
        use_key(cl)
    # Rita's launcher wrote it; she is a plain member, and it is Lee's answer
    inbox(rita, [signed("dc_1", "signup", {"raid": occ, "name": "lee", "class": "WARRIOR", "st": "A", "sp": 3})])
    settle(w, 5)
    assert rita.eval_py("return DisasterZoneBridgeDB.applied.dc_1")["ok"] is True
    for who in (bob, lee, rita):
        su = rp.signups(who, occ)[rp.K("Lee")]
        assert su["st"] == "A" and su["sp"] == 3 and su["dc"] == 1, (who, su)
    # the relay was taken by the others too (marked: their own launcher won't apply it again)
    assert bob.eval("return DisasterZoneBridgeDB.applied.dc_1 ~= nil")
    # a reminder's Running late: the note says it
    inbox(rita, [signed("dc_late", "signup", {"raid": occ, "name": "Lee", "class": "WARRIOR", "sp": 3, "st": "A",
                                               "note": "late 15 min"})])
    settle(w, 12)   # (a relay is ~3 KB: the chat throttle spreads it over a few seconds)
    assert rp.signups(bob, occ)[rp.K("Lee")]["n"] == "late 15 min"
    # a raid it can't take: marked not ok with the reason
    rp.call(bob, "CancelRaid", occ, "one")
    w.tick(3)
    inbox(rita, [signed("dc_2", "signup", {"raid": occ, "name": "Rita", "st": "T"})])
    settle(w)
    m = rita.eval_py("return DisasterZoneBridgeDB.applied.dc_2")
    assert m["ok"] is False and "cancelled" in m["why"], m
    no_errors(w)


@case
def forged_relays_and_host_messages_are_ignored():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    occ = rp.create(bob, i="kara", t=rp.now(bob) + 2 * rp.DAY)
    w.tick(3)
    for cl in c.values():
        use_key(cl)
    altered = signed("f1", "signup", {"raid": occ, "name": "Rita", "class": "PRIEST", "st": "X"})
    altered["body"]["st"] = "A"
    relay(lee, altered)
    relay(lee, {"id": "f2", "type": "signup", "at": 1, "by": "x", "sig": "nope", "body": {"raid": occ, "name": "Rita", "st": "A"}})
    # the old host broadcast (1.4) counts from nobody now
    lee.eval("local o, k = ...; ns.Comm:Send({ t = 'RPH', l = { { o = o, k = k, s = { st = 'A', rev = GetServerTime(), c = 'PRIEST' } } } }, 'GUILD')",
             occ, rp.K("Rita"))
    settle(w, 5)
    assert rp.K("Rita") not in rp.signups(bob, occ)
    assert bob.eval("return DisasterZoneBridgeDB == nil or (DisasterZoneBridgeDB.applied.f1 == nil and DisasterZoneBridgeDB.applied.f2 == nil)")
    # the real one, relayed by anyone, counts
    relay(lee, signed("f3", "signup", {"raid": occ, "name": "Rita", "class": "PRIEST", "st": "A"}))
    settle(w, 15)
    assert rp.signups(bob, occ)[rp.K("Rita")]["st"] == "A"
    no_errors(w)


@case
def a_guest_waits_for_someone_who_runs_the_raid():
    w, c = rp.world()
    gina, bob, rita = c["Gina"], c["Bob"], c["Rita"]
    occ = rp.create(bob, i="kara", t=rp.now(bob) + 2 * rp.DAY)
    w.tick(3)
    gina.logout()
    bob.logout()
    w.tick(3)
    recs = [signed("g1", "signup", {"raid": occ, "name": "Pugzor-Thunderstrike", "class": "MAGE", "sp": 3, "st": "A"}),
            signed("g2", "signup", {"raid": occ, "name": "Pugtwo-Thunderstrike", "class": "MAGE", "st": "T"})]
    # Rita can't add guests to Bob's raid: left for someone who can (not marked, not refused)
    inbox(rita, recs)
    settle(w)
    marks = rita.eval_py("return DisasterZoneBridgeDB.applied")
    assert "g1" not in marks, marks
    assert marks["g2"]["ok"] is False and "Guests can only accept" in marks["g2"]["why"], marks
    # Gina (the GM) loads the same inbox later: she can
    gina.login()
    w.tick(5)
    inbox(gina, recs + [signed("g3", "signup", {"raid": occ, "name": "gina", "class": "MAGE", "sp": 2, "st": "A"})])
    settle(w, 5)
    marks = gina.eval_py("return DisasterZoneBridgeDB.applied")
    assert marks["g1"]["ok"] is True and marks["g3"]["ok"] is True, marks
    su = rp.signups(gina, occ)
    assert su["Pugzor-Thunderstrike"]["guest"] is True and su["Pugzor-Thunderstrike"]["c"] == "MAGE", su
    # Gina is a Paladin in the roster: the Mage spec she typed is dropped, her class stays
    assert su[rp.K("Gina")]["c"] == "PALADIN" and su[rp.K("Gina")].get("sp") is None, su[rp.K("Gina")]
    no_errors(w)


@case
def snapshot_carries_my_bis_list():
    w, c = rp.world()
    gina = c["Gina"]
    gina.eval("ns.BiS:SetSlot(1, 1, 'main', 29068); ns.BiS:SetSlot(1, 1, 'alt', 29011); ns.BiS:Commit()")
    inbox(gina, [])
    gina.fire("PLAYER_LOGOUT")
    snap = gina.eval_py("return DisasterZoneBridgeDB.snap")
    mine = snap["bis"][rp.K("Gina")]
    assert mine["slots"][0]["id"] == 29068 and mine["slots"][0]["slot"] == "Head", mine
    assert mine["slots"][0]["alt"] == 29011 and mine["r"] >= 1, mine
    assert mine["class"] == "PALADIN" and gina.eval("return DisasterZoneBridgeDB.snap.bis[...].ph['1'][1].id", rp.K("Gina")) == 29068
    assert gina.eval("return DisasterZoneBridgeDB.snap.items[29068] ~= nil")
    no_errors(w)


@case
def snapshot_carries_the_roster():
    w, c = rp.world()
    gina = c["Gina"]
    inbox(gina, [])
    gina.fire("PLAYER_LOGOUT")
    roster = {r["key"]: r["class"] for r in gina.eval_py("return DisasterZoneBridgeDB.snap.roster")}
    assert roster[rp.K("Lee")] == "WARRIOR" and roster[rp.K("Rita")] == "PRIEST", roster
    assert gina.eval("return ns.Bridge:FindMember('LEE')") == rp.K("Lee")
    assert gina.eval("return DisasterZoneBridgeDB.snap.phase") >= 1
    assert gina.eval("return ns.Bridge:FindMember('Nobody')") is None
    no_errors(w)


@case
def discord_badges_reach_the_guild():
    w, c = rp.world()
    gina, lee, rita = c["Gina"], c["Lee"], c["Rita"]
    for cl in c.values():
        use_key(cl)
    inbox(rita, [signed("ln_1", "links", {"rev": 1792000000, "l": {"lee": "LeeOnDiscord", "Stranger": "x"}})])
    settle(w, 5)
    assert gina.eval("return ns.Bridge:GetDiscordName(...)", rp.K("Lee")) == "LeeOnDiscord"
    assert gina.eval("return ns.Bridge:GetDiscordName(...)", rp.K("Rita")) is None
    name = gina.eval("return ns.UI:ColoredName(...)", rp.K("Lee"))
    assert "Icons" in name and "Discord" in name, name
    assert "Discord" not in gina.eval("return ns.UI:ColoredName(...)", rp.K("Rita"))
    # a list without the bot's signature is ignored
    fake = signed("ln_2", "links", {"rev": 1792000500, "l": {"Rita": "fake"}})
    fake["body"]["l"]["Rita"] = "faker"
    lee.eval("local r = %s; r.sig = ns.Sha256.FromHex(r.sig); ns.Comm:Send({ t = 'DCL', r = r }, 'GUILD', nil, 'data')" % lua(fake))
    settle(w, 5)
    assert gina.eval("return ns.Bridge:GetDiscordName(...)", rp.K("Rita")) is None
    # a member who missed it gets it through the HELLO, from anyone who holds it
    sam = c["Sam"]
    sam.eval("local gk = ns.Guild:GetGuildKey(); if DisasterZoneDB.discordLinks then DisasterZoneDB.discordLinks[gk] = nil end")
    sam.relog()
    use_key(sam)
    w.tick(20)
    assert sam.eval("return ns.Bridge:GetDiscordName(...)", rp.K("Lee")) == "LeeOnDiscord"
    no_errors(w)


HEAD = 29068   # a plate helm (fits Head)


def bis(rid, name, item, phase=1, sid=1, **more):
    return signed(rid, "bis", dict({"name": name, "phase": phase, "sid": sid, "item": item, "which": "main"}, **more))


@case
def discord_bis_edit_of_my_own_list():
    w, c = rp.world()
    gina = c["Gina"]
    inbox(gina, [bis("b1", "Gina", HEAD)])
    settle(w)
    assert gina.eval_py("return DisasterZoneBridgeDB.applied.b1")["ok"] is True
    assert gina.eval("return (ns.BiS:GetSlot(1, 1))") == HEAD
    inbox(gina, [bis("b2", "Gina", 28244)])   # a necklace in the Head slot: refused with why
    settle(w)
    m = gina.eval_py("return DisasterZoneBridgeDB.applied.b2")
    assert m["ok"] is False and "doesn't fit" in m["why"], m
    no_errors(w)


@case
def discord_bis_edit_of_my_off_spec_list():
    w, c = rp.world()
    gina = c["Gina"]
    inbox(gina, [bis("o1", "Gina", HEAD, which="alt", list="os")])
    settle(w)
    assert gina.eval_py("return DisasterZoneBridgeDB.applied.o1")["ok"] is True
    assert gina.eval("return ns.BiS:HasOffSpec()") is True
    assert gina.eval("return select(2, ns.BiS:GetSlot(1, 1, 'os'))") == HEAD
    assert gina.eval("return (ns.BiS:GetSlot(1, 1))") is None
    no_errors(w)


@case
def discord_bis_edit_reaches_a_member_with_the_addon():
    w, c = rp.world()
    gina, lee = c["Gina"], c["Lee"]
    w.tick(5)   # (the guild's HELLOs: Gina knows Lee has the addon)
    lee.logout()
    w.tick(3)
    inbox(gina, [bis("b1", "lee", HEAD)])
    settle(w)
    assert gina.eval_py("return DisasterZoneBridgeDB.applied.b1")["ok"] is True
    assert len(gina.eval_py("return DisasterZoneBridgeDB.bisOut")[rp.K("Lee")]) == 1
    lee.login()
    use_key(lee)
    w.tick(30)
    assert lee.eval("return (ns.BiS:GetSlot(1, 1))") == HEAD
    assert gina.eval("local o = DisasterZoneBridgeDB.bisOut; return o[...] == nil", rp.K("Lee"))
    # (the 1.4 host message changes nothing any more)
    c["Bob"].eval("ns.Comm:Send({ t = 'BDE', e = { { id = 'x', p = 1, s = 1, i = 0, w = 'main' } } }, 'WHISPER', ...)", rp.K("Lee"))
    w.tick(3)
    assert lee.eval("return (ns.BiS:GetSlot(1, 1))") == HEAD
    no_errors(w)


@case
def discord_bis_edit_for_a_member_without_the_addon_needs_the_council():
    w, c = rp.world()
    gina, rita = c["Gina"], c["Rita"]
    w.add_offline_member("Nomad", "WARRIOR", 3)
    w.tick(5)
    inbox(rita, [bis("b1", "nomad", HEAD)])        # a plain member: left for the council
    settle(w)
    assert rita.eval("return DisasterZoneBridgeDB.applied.b1 == nil")
    inbox(gina, [bis("b1", "nomad", HEAD)])        # the GM is on the council
    settle(w)
    m = gina.eval_py("return DisasterZoneBridgeDB.applied.b1")
    assert m["ok"] is True, m
    assert gina.eval("return ns.Store:Get(...).data.ph[1][1][1]", rp.K("Nomad")) == HEAD
    no_errors(w)


if __name__ == "__main__":
    run_all()
