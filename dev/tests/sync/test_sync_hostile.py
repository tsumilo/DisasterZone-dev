#!/usr/bin/env python
"""(f) Forged / hostile / malformed traffic against the REAL addon (SPEC §10.1 receive gates, §10.2 sender gates).
Nothing may be accepted and nothing may raise a Lua error.

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_sync_hostile.py   [-k substring]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (Runner, Client, new_world, up, settle, key, edit, own, cached, cached_rev, logical_messages,  # noqa: E402
                    traffic, fmt_traffic, printed, wipe_saved)

r = Runner("hostile traffic")
RK, R2K, C1K, C2K, SK = key("Raider"), key("Raiderb"), key("Councila"), key("Councilb"), key("Sneaky")
DAY = 1790000000 // 86400

ENC_LUA = r"""
__enc = function(msg, major)
  local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
  return (major or "1") .. LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
end
__raw = function(prefix, text, dist, target)
  ns.Comm:SendCommMessage(prefix, text, dist, target, "NORMAL")
end
"""


def setup(outsider=False):
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    R2 = Client(w, "Raiderb", class_file="WARRIOR", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1)
    S = Client(w, "Sneaky", class_file="ROGUE", guild_rank=3)          # guild member, NOT council
    O = Client(w, "Stranger", class_file="WARLOCK", guild="Evil Empire", guild_rank=0) if outsider else None
    w.add_offline_member("Oldguy", "ROGUE", 3)
    for c in (R, R2, C1, C2, S) + ((O,) if O else ()):
        up(c)
        c.eval(ENC_LUA)
    settle(w, 30)
    edit(R, 0, commit=True)
    edit(R2, 1, commit=True)
    C1.eval("ns.Ledger:Award(...)", 28586, RK, "", "real award")
    settle(w, 20)
    assert cached_rev(C1, RK) == 1 and cached_rev(C2, RK) == 1
    return w, R, R2, C1, C2, S, O


def send_as(c, msg, dist, target=None, cls="ctrl"):
    return c.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", msg, dist, target, cls)


def send_lua(c, lua_msg_expr, dist, target=None, cls="ctrl"):
    """Build the message table in the sender's Lua (for shapes Python cannot express) and send it."""
    return c.eval("local d, t, cl = ... local m = (%s) return ns.Comm:Send(m, d, t, cl)" % lua_msg_expr, dist, target, cls)


def raw(c, prefix, text_lua, dist, target=None):
    c.eval("local p, d, t = ... __raw(p, (%s), d, t)" % text_lua, prefix, dist, target)


STATE_LUA = """
  local lists = {}
  for k, v in pairs(ns.db.lists) do lists[k] = { v.rev, v.hash, v.via } end
  local led = {}
  for id, e in pairs(ns.db.ledger) do led[id] = tostring(e.vd) .. ":" .. tostring(e.vts) .. ":" .. tostring(e.w) end
  local rec = ns.BiS:GetRecord()
  return { lists = lists, ledger = led, rev = rec.rev, hsr = rec.highestSeenRev, hash = rec.hash }"""


def state_of(c):
    return c.eval_py(STATE_LUA)


def snapshot(clients):
    return {c.full_name: state_of(c) for c in clients}


def assert_unchanged(before, clients, what):
    for c in clients:
        now = state_of(c)
        assert now == before[c.full_name], "%s: state changed after %s\nbefore %s\nafter  %s" % (
            c.full_name, what, before[c.full_name], now)


def replies_to(w, mark, name, exclude_types=()):
    return [(m["sender"], m["t"]) for m in logical_messages(w, mark)
            if (m["target"] or "").split("-")[0] == name and m["t"] not in exclude_types]


def own_wire_entry(c):
    return c.eval_py("local r = ns.BiS:GetRecord() return { r = r.rev, ts = r.ts, h = r.hash, d = r.data }")


# ------------------------------------------------------------------------------------------------------------------
@r.case
def f_non_council_forged_sync_messages_rejected():
    w, R, R2, C1, C2, S, _ = setup()
    victims = (R, R2, C1, C2)
    before = snapshot(victims)
    ent = own_wire_entry(R)
    newer = dict(ent, r=99, o=RK)
    mark = len(w.addon_log)
    send_as(S, {"t": "R", "e": [newer]}, "WHISPER", C1K, "data")            # RELAY of R's list to council
    send_as(S, {"t": "R", "e": [newer]}, "WHISPER", RK, "data")             # RELAY of R's own list to R
    send_as(S, {"t": "S", "r": 77}, "WHISPER", RK)                           # STATE: "I have rev 77 of yours"
    send_as(S, {"t": "M", "m": {RK: 60}, "ld": {DAY: "deadbeef"}, "q": True}, "WHISPER", C1K)
    send_as(S, {"t": "W", "n": [RK, R2K]}, "WHISPER", C1K)                   # WANT others' lists
    send_as(S, {"t": "W", "n": [RK]}, "WHISPER", C2K)                        # WANT R's list only
    send_as(S, {"t": "W", "n": [RK]}, "WHISPER", RK)                         # WANT R's list from R
    award = {"id": "m1790000100Sneaky28588", "i": 28588, "w": SK, "b": "", "ts": 1790000100, "by": SK, "s": "m"}
    send_as(S, {"t": "A", "e": award}, "WHISPER", C1K)
    send_as(S, {"t": "LG", "e": [award]}, "WHISPER", C2K, "data")
    send_as(S, {"t": "LW", "d": [DAY, DAY - 1]}, "WHISPER", C1K)
    led_id = list(C1.eval_py("local t = {} for id in pairs(ns.db.ledger) do t[#t+1] = id end return t"))[0]
    void = dict(C1.eval_py("return ns.db.ledger[...]", led_id), vd=True, vts=1790009999)
    send_as(S, {"t": "A", "e": void}, "WHISPER", C2K)                         # try to void a real award
    # a HELLO that claims to be council with a manifest saying R has rev 99
    send_as(S, {"t": "H", "r": 0, "v": "0.1.0", "c": True, "m": {RK: 99, R2K: 99}, "ld": {DAY: "deadbeef"}}, "GUILD")
    settle(w, 30)
    assert_unchanged(before, victims, "forged non-council messages")
    rep = replies_to(w, mark, "Sneaky", exclude_types=("S",))   # a council S reply to any HELLO is normal
    assert not rep, "someone answered forged requests: %s" % rep
    assert R.popups() == [], R.popups()
    assert SK not in (R.eval_py("return ns.Sync:GetOnlineCouncilPeers()") or [])
    w.assert_no_errors()


@r.case
def f_list_for_someone_else_is_stored_under_the_sender_only():
    w, R, R2, C1, C2, S, _ = setup()
    before_r = cached(C1, RK)
    ent = own_wire_entry(R)
    forged = dict(ent, r=50, o=RK, owner=RK, n=RK)      # payload claims to be R's list
    forged["t"] = "L"
    send_as(S, forged, "WHISPER", C1K, "data")
    settle(w, 5)
    assert cached(C1, RK) == before_r, "C1's copy of R changed: %s -> %s" % (before_r, cached(C1, RK))
    got = cached(C1, SK)
    assert got is not None and got["rev"] == 50, "the list should be filed under the transport sender: %s" % got
    w.assert_no_errors()


@r.case
def f_forged_relay_during_restore_window_ignored():
    """R reinstalls; while its restore request is in flight a non-council member floods forged relays of
    R's own list (valid hash, higher rev). R must restore the council's copy, not the forgery."""
    w, R, R2, C1, C2, S, _ = setup()
    good = own(R)
    fake_data = S.eval_py("return ns.BiS:GetRecord().data")
    fake_hash = S.eval("return ns.Util.Hash(ns.BiS:GetRecord().data)")
    R.logout()
    wipe_saved(w, R)
    R.login()
    for _ in range(45):
        send_as(S, {"t": "R", "e": [{"o": RK, "r": 999, "ts": 1790000000, "h": fake_hash, "d": fake_data}]},
                "WHISPER", RK, "data")
        w.tick(1.0)
    o = own(R)
    assert o["hash"] == good["hash"] and o["rev"] == good["rev"], "R adopted %s, council copy %s" % (o, good)
    assert o["hsr"] < 999, "forged relay raised highestSeenRev: %s" % o
    w.assert_no_errors()


@r.case
def f_outsider_messages_dropped_and_not_held_forever():
    w, R, R2, C1, C2, S, O = setup(outsider=True)
    victims = (R, R2, C1, C2)
    before = snapshot(victims)
    ent = own_wire_entry(R)
    for tgt in (RK, C1K):
        send_as(O, {"t": "R", "e": [dict(ent, r=99, o=RK)]}, "WHISPER", tgt, "data")
        send_as(O, {"t": "S", "r": 50}, "WHISPER", tgt)
        send_as(O, {"t": "W", "n": [RK]}, "WHISPER", tgt)
        send_as(O, dict(ent, t="L", r=40), "WHISPER", tgt, "data")
        raw(O, "CDLc", '__enc({ t = "S", r = 5 }, "7")', "WHISPER", tgt)  # wrong major from an outsider
    # Comm refuses WHISPER to targets not in the sender's roster: go below the addon's Comm
    for tgt in ("Raider", "Councila"):
        raw(O, "CDLc", '__enc({ t = "S", r = 50 })', "WHISPER", tgt)
        raw(O, "CDLd", '__enc({ t = "R", e = { { o = "Raider-Thunderstrike", r = 99 } } })', "WHISPER", tgt)
    w.tick(2)
    held = {c.full_name: c.eval("return ns.Comm:GetHeldCount()") for c in (R, C1)}
    settle(w, 90)
    assert_unchanged(before, victims, "outsider messages")
    for c in (R, C1):
        assert c.eval("return ns.Comm:GetHeldCount()") == 0, "%s still holds outsider messages" % c.full_name
        assert not [p for p in printed(c) if "incompatible" in p], "outsider triggered a protocol notice"
    r.note("outsider messages held right after receipt: %s (all dropped later)" % held)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# malformed payloads (from a guild member and from a council member)
# ------------------------------------------------------------------------------------------------------------------
MALFORMED_RAW = [
    # (prefix, text lua expression, dist)
    ("CDLc", '"1"', "WHISPER"),
    ("CDLc", '"1!!!!not-a-deflate-stream!!!!"', "WHISPER"),
    ("CDLc", '"1" .. LibStub("LibDeflate"):EncodeForWoWAddonChannel("\\255\\254garbage")', "WHISPER"),
    ("CDLc", '"1" .. LibStub("LibDeflate"):EncodeForWoWAddonChannel(LibStub("LibDeflate"):CompressDeflate("not libserialize"))', "WHISPER"),
    ("CDLc", '__enc("just a string")', "WHISPER"),
    ("CDLc", '__enc(12345)', "WHISPER"),
    ("CDLc", '__enc({ x = 1 })', "WHISPER"),
    ("CDLc", '__enc({ t = 123 })', "WHISPER"),
    ("CDLc", '__enc({ t = "ZZ" })', "WHISPER"),
    ("CDLc", '__enc({ t = "H", r = 1 })', "WHISPER"),                 # HELLO must come on GUILD
    ("CDLc", '__enc({ t = "S", r = 1 })', "GUILD"),                   # STATE must be a whisper
    ("CDLc", '__enc({ t = "H", r = "x", v = 12345, c = "yes", m = "nope", ld = { 1, 2, 3 } })', "GUILD"),
    ("CDLc", '__enc({ t = "H", r = -1, v = string.rep("9", 200), c = true, m = { [1] = 5, ["Raider-Thunderstrike"] = -3, ["Raiderb-Thunderstrike"] = 1.5, ["bad|key"] = 5, [string.rep("x", 100)] = 5, ["Oldguy-Thunderstrike"] = 1e300 }, ld = { x = "y", [%d] = 5, [%d] = {} } })' % (DAY, DAY + 1), "GUILD"),
    ("CDLc", '__enc({ t = "H", r = 1, v = "0.1.0", c = true, m = (function() local m = {} for i = 1, 3000 do m["Fake" .. i .. "-Thunderstrike"] = i end return m end)() })', "GUILD"),
    ("CDLc", '__enc({ t = "S", r = -1 })', "WHISPER"),
    ("CDLc", '__enc({ t = "S", r = 1.5 })', "WHISPER"),
    ("CDLc", '__enc({ t = "S", r = 1e308 })', "WHISPER"),
    ("CDLc", '__enc({ t = "S", r = {} })', "WHISPER"),
    ("CDLc", '__enc({ t = "M", m = "x", ld = "y" })', "WHISPER"),
    ("CDLc", '__enc({ t = "M", m = { [5] = {} }, ld = { [-1] = "x" }, q = "yes" })', "WHISPER"),
    ("CDLc", '__enc({ t = "W", n = "Raider-Thunderstrike" })', "WHISPER"),
    ("CDLc", '__enc({ t = "W", n = { 1, {}, true, "", string.rep("y", 300), "a|b" } })', "WHISPER"),
    ("CDLc", '__enc({ t = "W", n = (function() local n = {} for i = 1, 500 do n[i] = "Raider-Thunderstrike" end return n end)() })', "WHISPER"),
    ("CDLd", '__enc({ t = "L", r = 1.5, ts = "x", h = {}, d = "string" })', "WHISPER"),
    ("CDLd", '__enc({ t = "L", r = 5, ts = 1, h = "00000000", d = { v = 1, ph = { [9] = {} } } })', "WHISPER"),
    ("CDLd", '__enc({ t = "L", r = 5, ts = 1, h = "00000000", d = (function() local d = { v = 1 } local cur = d for i = 1, 60 do cur.x = {} cur = cur.x end return d end)() })', "WHISPER"),
    ("CDLd", '__enc({ t = "L", r = 5, ts = 1, h = "00000000", d = { v = 1, ob = (function() local o = {} for i = 1, 5000 do o[i] = i end return o end)() } })', "WHISPER"),
    ("CDLd", '__enc({ t = "L", r = 2^53, ts = 1, h = "x", d = { v = 1 } })', "WHISPER"),
    ("CDLd", '__enc({ t = "L" })', "WHISPER"),
    ("CDLd", '__enc({ t = "R", e = "x" })', "WHISPER"),
    ("CDLd", '__enc({ t = "R", e = { 1, 2, { o = 5 }, { o = "Raider-Thunderstrike", r = "x" }, { o = "Raider-Thunderstrike", r = 5, h = "1", d = { v = "bad" } }, { o = "|cff", r = 1 } } })', "WHISPER"),
    ("CDLd", '__enc({ t = "R", e = (function() local e = {} for i = 1, 100 do e[i] = { o = "Raiderb-Thunderstrike", r = i, h = "x", d = { v = 1 } } end return e end)() })', "WHISPER"),
    ("CDLc", '__enc({ t = "A", e = "x" })', "WHISPER"),
    ("CDLc", '__enc({ t = "A", e = { id = string.rep("i", 200), i = 0, w = "", by = 5, ts = -1, s = "z", vd = "yes", vts = -5, n = string.rep("n", 1000) } })', "WHISPER"),
    ("CDLc", '__enc({ t = "A", e = { id = "a1", i = 1.5, w = "Raider", by = "Councilb", ts = 1e20, s = "a" } })', "WHISPER"),
    ("CDLc", '__enc({ t = "LW", d = "x" })', "WHISPER"),
    ("CDLc", '__enc({ t = "LW", d = { -1, 1.5, "x", {}, 1e12 } })', "WHISPER"),
    ("CDLc", '__enc({ t = "LW", d = (function() local d = {} for i = 1, 1000 do d[i] = %d - i end return d end)() })' % DAY, "WHISPER"),
    ("CDLd", '__enc({ t = "LG", e = "x" })', "WHISPER"),
    ("CDLd", '__enc({ t = "LG", e = { "x", {}, { id = 5 }, { id = "ok", i = "x" } } })', "WHISPER"),
    ("CDLd", '__enc({ t = "LG", e = (function() local e = {} for i = 1, 100 do e[i] = { id = "junk" .. i, i = 999999, w = "x", by = "y", ts = 1, s = "a" } end return e end)() })', "WHISPER"),
]


def run_malformed(sender, targets, w):
    for prefix, expr, dist in MALFORMED_RAW:
        if dist == "GUILD":
            raw(sender, prefix, expr, "GUILD")
        else:
            for tgt in targets:
                raw(sender, prefix, expr, "WHISPER", tgt)
        w.tick(0.5)


@r.case
def f_malformed_payloads_from_guild_member():
    w, R, R2, C1, C2, S, _ = setup()
    victims = (R, R2, C1, C2)
    before = snapshot(victims)
    mark = len(w.addon_log)
    run_malformed(S, ("Raider", "Councila"), w)
    settle(w, 120)
    assert_unchanged(before, victims, "malformed payloads from a guild member")
    rep = replies_to(w, mark, "Sneaky", exclude_types=("S",))
    assert not rep, rep
    w.assert_no_errors()


@r.case
def f_malformed_payloads_from_council_member():
    """A buggy/newer council client: garbage must never raise errors. (Valid-but-junk content from council
    such as 'S r=1e308' may legitimately trigger a push; only errors and state corruption are checked.)"""
    w, R, R2, C1, C2, S, _ = setup()
    before_r = own(R)
    before_c1 = {k: v for k, v in state_of(C1)["lists"].items()}
    before_led = state_of(C1)["ledger"]
    run_malformed(C2, ("Raider", "Councila"), w)
    settle(w, 150)
    o = own(R)
    assert o["hash"] == before_r["hash"] and o["rev"] == before_r["rev"], (before_r, o)
    after_c1 = state_of(C1)
    for k, v in before_c1.items():
        assert after_c1["lists"].get(k, [None])[:2] == v[:2], "C1 copy of %s changed: %s -> %s" % (k, v, after_c1["lists"].get(k))
    junk = [k for k in after_c1["lists"] if k.startswith("Fake")]
    assert not junk, "C1 accepted lists for names not in the guild: %s" % junk[:5]
    assert after_c1["ledger"] == before_led, (before_led, after_c1["ledger"])
    w.assert_no_errors()


@r.case
def f_oversized_payload_dropped():
    w, R, R2, C1, C2, S, _ = setup()
    victims = (R, C1)
    before = snapshot(victims)
    # ~30 KB of incompressible data -> > 24,000 wire bytes (MAX_WIRE_LEN)
    S.eval("""
      local t, x = {}, 12345
      for i = 1, 30000 do x = (x * 16807) % 2147483647; t[i] = string.char(x % 256) end
      __big = table.concat(t)""")
    size = S.eval('return #__enc({ t = "H", r = 1, v = "0.1.0", pad = __big })')
    assert size > 24000, size
    mark = len(w.addon_log)
    raw(S, "CDLc", '__enc({ t = "S", r = 1, pad = __big })', "WHISPER", "Raider")
    raw(S, "CDLc", '__enc({ t = "H", r = 1, v = "0.1.0", pad = __big })', "GUILD")
    settle(w, 300)                                   # ~120 parts per message at 1 msg/s (server throttle)
    parts = len([e for e in w.addon_log[mark:] if e["sender"] == SK])
    assert_unchanged(before, victims, "an oversized message")
    dropped = R.eval("return ns.Comm.stats.dropped")
    assert dropped >= 2, "oversized messages were not counted as dropped on R: %s" % dropped
    r.note("oversized: %d wire bytes per message, %d parts sent in total" % (size, parts))
    w.assert_no_errors()


@r.case
def f_decompression_bomb_is_cheap_to_reject():
    """A message under the 24,000-byte wire cap that inflates to ~8 MB is rejected by MAX_INFLATED_LEN (200 KB),
    but only AFTER LibDeflate inflated all of it (Comm.lua Decode). Every online guild member pays that for one
    GUILD message. Measure the receivers' stall (wall clock of the delivering tick)."""
    w, R, R2, C1, C2, S, _ = setup()
    S.eval('''local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
      __bomb = "1" .. LD:EncodeForWoWAddonChannel(LD:CompressDeflate(
        LS:Serialize({ t = "H", r = 1, v = "0.1.0", pad = string.rep("A", 8000000) }), { level = 9 }))''')
    wire = S.eval("return #__bomb")
    assert wire < 24000, wire
    raw(S, "CDLc", "__bomb", "GUILD")
    worst = 0.0
    for _ in range(200):                             # ~80 parts at 1 msg/s (server throttle)
        t0 = time.time()
        w.tick(0.5, 0.5)
        worst = max(worst, time.time() - t0)
        if C1.eval("return ns.Comm.stats.dropped") >= 1:
            break
    dropped = C1.eval("return ns.Comm.stats.dropped")
    per_receiver = worst / 4                         # R, R2, C1, C2 inflate the same message in the same tick
    r.note("decompression bomb: %d wire bytes -> 8 MB inflated; delivering tick took %.2fs for 4 receivers "
           "(~%.2fs Lua time each)" % (wire, worst, per_receiver))
    assert dropped >= 1, "bomb not rejected"
    w.assert_no_errors()
    assert per_receiver < 0.1, ("one %d-byte GUILD message from any guild member costs every online member "
                                "~%.2fs of Lua time (inflate happens before the MAX_INFLATED_LEN check)"
                                % (wire, per_receiver))


@r.case
def f_wrong_protocol_major_noted_once_and_ignored():
    """An (honest) client with protocol 2: every message is ignored, one notice per peer."""
    w, R, R2, C1, C2, S, _ = setup()
    victims = (R, R2, C1, C2)
    before = snapshot(victims)
    for i in range(5):
        raw(S, "CDLc", '__enc({ t = "H", r = 50, v = "9.0.0", c = true, m = { ["Raider-Thunderstrike"] = 99 } }, "2")', "GUILD")
        raw(S, "CDLc", '__enc({ t = "S", r = 99 }, "2")', "WHISPER", "Raider")
        raw(S, "CDLd", '__enc({ t = "R", e = {} }, "2")', "WHISPER", "Councila")
        w.tick(1)
    settle(w, 10)
    assert_unchanged(before, victims, "wrong-protocol messages")
    for c in (R, R2, C1, C2):
        notes = [p for p in printed(c) if "incompatible" in p]
        assert len(notes) == 1, "%s: expected one incompatible-version notice, got %d" % (c.full_name, len(notes))
    w.assert_no_errors()


@r.case
def f_alternating_protocol_majors_do_not_flood_chat():
    """A hostile guild member alternates the first byte ("2", "3", ...) on GUILD messages: NotePeerProtocol
    only remembers the LAST major per sender, so every switch prints a new chat line on every guild member."""
    w, R, R2, C1, C2, S, _ = setup()
    before = snapshot((R, C1))
    for i in range(10):
        major = "23"[i % 2]
        raw(S, "CDLc", '__enc({ t = "H", r = 1, v = "0.1.0" }, "%s")' % major, "GUILD")
        w.tick(1.2)
    settle(w, 10)
    assert_unchanged(before, (R, C1), "alternating-major messages")
    notes = [p for p in printed(R) if "incompatible" in p]
    w.assert_no_errors()
    assert len(notes) <= 2, "10 GUILD messages with alternating majors printed %d chat lines on every member" % len(notes)


@r.case
def f_hash_mismatch_rejected():
    w, R, R2, C1, C2, S, _ = setup()
    before = snapshot((R, C1))
    ent = own_wire_entry(R)
    bad = dict(ent, r=5, o=RK, h="0badbad0")
    send_as(C2, {"t": "R", "e": [bad]}, "WHISPER", C1K, "data")            # council relay, wrong hash
    send_as(R2, dict(own_wire_entry(R2), t="L", r=9, h="0badbad0"), "WHISPER", C1K, "data")   # owner push, wrong hash
    tampered = dict(ent, r=6, o=RK)
    tampered["d"] = dict(ent["d"], sp="Retribution")                       # data changed, hash kept
    send_as(C2, {"t": "R", "e": [tampered]}, "WHISPER", C1K, "data")
    settle(w, 10)
    assert_unchanged(before, (C1,), "relays with a wrong hash")
    assert cached_rev(C1, R2K) == 1, "owner push with a wrong hash accepted"
    w.assert_no_errors()


@r.case
def f_restore_relay_with_wrong_hash_not_adopted():
    w, R, R2, C1, C2, S, _ = setup()
    good = own(R)
    # C2 is a council member with a corrupted copy of R's list (hash does not match data, higher rev)
    C2.eval("""
      local rec = ns.db.lists["Raider-Thunderstrike"]
      rec.rev = 7
      rec.data.sp = "Protection"   -- data changed, hash not recomputed
    """)
    C1.logout()
    R.logout()
    wipe_saved(w, R)
    R.login()
    settle(w, 60)
    o = own(R)
    assert not (o["rev"] == 7 or R.eval("return ns.BiS:GetData().sp") == "Protection"), \
        "R adopted a relay whose hash does not match its data: %s" % o
    assert o["rev"] == 0, "nothing valid to restore: the list must stay empty (rev 0), got %s" % o
    w.assert_no_errors()


@r.case
def f_council_state_with_huge_rev_does_not_brick_the_list():
    """A (buggy or hostile) council member answers with STATE r=1e9. Sync accepts revs up to 1e9 (IsRev) and
    BiS:NoteSeenRev raises highestSeenRev to it, so the owner's next commit becomes rev 1e9+1 - which Sync's own
    IsRev() rejects (MAX_REV = 1e9, while Store accepts up to 2^31-1). The owner's list must stay shareable."""
    w, R, R2, C1, C2, S, _ = setup()
    send_as(C2, {"t": "S", "r": 1000000000}, "WHISPER", RK)
    settle(w, 10)
    for p in R.popups():
        R.accept_popup(p)                              # "Restore" (C2 only has rev 1: nothing to adopt)
    settle(w, 10)
    edit(R, 2, sid=5, commit=True)
    settle(w, 15)
    o = own(R)
    c = cached(C1, RK)
    problems = []
    if not (c is not None and c["rev"] == o["rev"] and c["hash"] == o["hash"]):
        problems.append("the owner's new edit (own rev %s) never reached C1 (C1 holds rev %s)" % (o["rev"], c and c["rev"]))
    R.relog()                                          # next session: does the local edit survive?
    settle(w, 45)
    o2 = own(R)
    if o2["hash"] != o["hash"]:
        problems.append("after a /reload the owner's newer local list (hash %s) was replaced by the council's old "
                        "copy (rev %s, hash %s)" % (o["hash"], o2["rev"], o2["hash"]))
    w.assert_no_errors()
    assert not problems, "after one STATE r=1e9: " + "; ".join(problems)


if __name__ == "__main__":
    r.run()
