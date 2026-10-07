#!/usr/bin/env python
"""Addendum E §34: the picked loot council (Guild Master + current raid leader) on the real addon, mocked clients.

- The GM picks members (CG on GUILD): every online client sees them as council; an offline member gets the list
  after logging in (CQ: from the GM, or relayed by a council member while the GM is offline, trust on first use).
- Forged / relayed CG trust rules (§31): GM-direct, relay by a council member of the receiver's current list, TOFU
  only when the relayer is on the relayed list, the current GM as `by`, no older revs, no revs > now + 300,
  malformed lists dropped.
- The GM removes a member: council views and whisper gates close for that member everywhere.
- The raid leader's list (CR on RAID): raid scope only, cleared on disband, re-shared when leading again, the
  leader change mid-raid, CRQ after joining / reloading, forged CR ignored, a pug raid leader from another guild
  (1.3: never council, its CR is ignored; a pug on a raid list is not council either).
- 1.3: an unconfirmed (TOFU) guild list makes nobody council until the GM confirms it; the GM's own CG outranks a
  relayed list whatever its rev, and the GM shares its list again when a newer rev is advertised.
- The raid leader is council for their raid (Council tab in the raid, gone after leaving).
- The searchable dropdown: substring filter, draft toggles, Save & share only after a change, Revert, Clear with
  confirmation, "Show offline members", raid members first for the raid list.
- Migration: an old guildCfg is dropped, the notice prints once (only if it held a tag), and nothing reads or
  writes the Guild Information (spy on C_GuildInfo.GetInfoText / SetInfoText, GetGuildInfoText /
  SetGuildInfoText, plus a static scan of the addon source).
- Sync: a raid-council member receives the raid members' lists after being picked; guild-list council gets all.

Every case ends with world.assert_no_errors(). Standalone; prints PASS/FAIL per case, exit code 1 on a failure.
Run: luaenv\\Scripts\\python.exe tests\\council\\test_council_picker.py   [-k substring]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))

from _common import (case, run_all, no_errors, World, Client, ExtraMember, install_helpers, printed_since,  # noqa: E402
                     strip_codes, seed_guild_council, gm_pick, raid_pick, GUILD_INFO_SPY, guild_info_calls)
import lr_common as lr  # noqa: E402

REALM = "Thunderstrike"
ADDON_DIR = os.path.normpath(r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone")


def K(name):
    return name if "-" in name else "%s-%s" % (name, REALM)


# ------------------------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------------------------
def guild_world(specs, spy=True, tick=3, **world_kw):
    """specs: [(name, rank, class)] online clients (loaded), or (name, rank, class, False) = created offline."""
    w = World(**world_kw)
    cs = {}
    for sp in specs:
        name, rank, cls = sp[0], sp[1], sp[2]
        online = sp[3] if len(sp) > 3 else True
        cs[name] = Client(w, name, guild_rank=rank, class_file=cls, online=online,
                          preload_lua=GUILD_INFO_SPY if spy else None)
    for c in cs.values():
        if c.online:
            c.load_addon()
    w.tick(tick)
    return w, cs


def council(c, name=None):
    if name is None:
        return c.eval("return ns.Guild:AmICouncil(true)")
    return c.eval("return ns.Guild:IsCouncil(..., true)", K(name))


def source(c, name):
    return c.eval("return ns.Guild:GetCouncilSource(...)", K(name))


def guild_list(c):
    g = c.eval_py("return ns.Guild:GetGuildCouncil()")
    if not g:
        return None
    return {"rev": g["rev"], "members": sorted((g.get("members") or {}).keys()), "phase": g.get("phase"),
            "by": g.get("by")}


def raid_list(c):
    r = c.eval_py("return ns.Guild:GetRaidCouncil()")
    if not r:
        return None
    return {"leader": r.get("leader"), "rev": r.get("rev"), "members": sorted((r.get("members") or {}).keys())}


def tabs(c):
    return c.eval_py("""
      local out = {}
      local f = DisasterZoneMainFrame
      if not f or not f.Tabs then return out end
      for _, k in ipairs(ns.MainFrame:GetShownPages()) do out[#out + 1] = k end
      return out""") or []


def open_window(c):
    if not c.eval("return ns.MainFrame:IsShown()"):
        c.slash("/dz")
        c.world.tick(0.3)


def msgs(w, t, start=0):
    return lr.msgs_of_type(w, t, start)


def send_as(c, msg, dist, target=None, cls="ctrl"):
    return c.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", msg, dist, target, cls)


def now(c):
    return c.eval("return GetServerTime()")


def assert_no_guild_info(cs):
    for c in cs:
        if c.runtime is not None:
            assert guild_info_calls(c) == [], "%s called the Guild Info API: %s" % (c.full_name, guild_info_calls(c))


# ------------------------------------------------------------------------------------------------------------------
# guild council (CG / CQ)
# ------------------------------------------------------------------------------------------------------------------
@case
def gm_picks_three_members_and_every_online_client_sees_them():
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Olaf", 1, "MAGE"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"),
                        ("Tess", 3, "DRUID"), ("Uma", 2, "HUNTER")])
    for n in c:
        assert c[n].eval("return ns.Guild:GetGM()") == K("Gina"), n
        assert council(c[n], "Gina") is True and source(c[n], "Gina") == "gm", n
        assert council(c[n], "Olaf") is False, "%s: an officer is not council by rank any more" % n
    mark = len(w.addon_log)
    rev = gm_pick(w, c["Gina"], ["Rita", "Sam", "Olaf"], phase=2)
    cg = msgs(w, "CG", mark)
    assert len(cg) == 1 and cg[0]["_chat_type"] == "GUILD" and cg[0]["_sender"] == K("Gina"), cg
    assert cg[0]["by"] == K("Gina") and cg[0]["ph"] == 2 and cg[0]["rev"] == rev, cg[0]
    assert sorted(cg[0]["m"]) == [K("Olaf"), K("Rita"), K("Sam")], cg[0]["m"]
    for n in c:
        g = guild_list(c[n])
        assert g and g["members"] == [K("Olaf"), K("Rita"), K("Sam")] and g["phase"] == 2 and g["by"] == K("Gina"), (n, g)
        for m in ("Rita", "Sam", "Olaf"):
            assert council(c[n], m) is True and source(c[n], m) == "guild", (n, m)
        for m in ("Tess", "Uma"):
            assert council(c[n], m) is False, (n, m)
        assert c[n].eval("return ns.Guild:GetGuildPhase()") == 2, n
    for n in ("Rita", "Sam", "Olaf", "Gina"):
        open_window(c[n])
        assert "council" in tabs(c[n]), (n, tabs(c[n]))
    for n in ("Tess", "Uma"):
        open_window(c[n])
        assert tabs(c[n]) == ["home", "mybis", "atlas", "raids", "dungeons", "events", "members", "games", "changelog", "settings"], (n, tabs(c[n]))
    # only the GM may save the guild list
    res = c["Olaf"].eval_py("local ok, err = ns.Guild:SetGuildCouncil({}); return { ok = ok, err = err }")
    assert res.get("ok") is False and res.get("err"), res
    assert c["Olaf"].eval("return ns.Guild:CanEditGuildCouncil()") is False
    assert c["Gina"].eval("return ns.Guild:CanEditGuildCouncil()") is True
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def offline_member_logs_in_later_and_gets_the_list_from_the_gm():
    # Only the GM is online among the council: the newcomer's query is answered by the GM itself.
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST", False), ("Lara", 3, "DRUID", False)])
    w.add_offline_member("Olaf", "MAGE", 1)
    rev = gm_pick(w, c["Gina"], ["Rita", "Olaf"], phase=3)
    mark = len(w.addon_log)
    c["Rita"].login()
    took = w.run_until(lambda: c["Rita"].eval("return ns.Guild:GetGuildCouncilRev()") == rev, timeout=45)
    cg = [m for m in msgs(w, "CG", mark) if m["_sender"] == K("Gina")]
    assert cg, "the GM did not answer the newcomer's query"
    cq = [m for m in msgs(w, "CQ", mark) if m["_sender"] == K("Rita")]
    assert cq, "no CQ from the newcomer"
    assert council(c["Rita"]) is True and c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 3
    print("     (list from the GM %.1fs after login, CQ via %s)" % (took, [m["_chat_type"] for m in cq]))
    # a member whose stored list is older (and < 7 days old) learns the new one from a council HELLO / STATE
    c["Rita"].logout()
    w.tick(2)
    rev2 = gm_pick(w, c["Gina"], ["Rita", "Olaf", "Lara"], phase=3)
    assert rev2 > rev
    c["Rita"].login()
    w.run_until(lambda: c["Rita"].eval("return ns.Guild:GetGuildCouncilRev()") == rev2, timeout=45)
    assert council(c["Rita"], "Lara") is True
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def offline_member_gets_the_list_relayed_by_a_council_member_while_the_gm_is_offline():
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST"), ("Lara", 3, "DRUID", False)])
    rev = gm_pick(w, c["Gina"], ["Rita"], phase=4)
    c["Gina"].logout()
    w.tick(2)
    mark = len(w.addon_log)
    c["Lara"].login()                                  # a fresh client: no stored list at all
    w.run_until(lambda: c["Lara"].eval("return ns.Guild:GetGuildCouncilRev()") == rev, timeout=50)
    cg = [m for m in msgs(w, "CG", mark)]
    assert cg and all(m["_sender"] == K("Rita") for m in cg), [(m["_sender"], m["_chat_type"]) for m in cg]
    assert cg[0]["by"] == K("Gina"), "a relayed list keeps the GM as its author"
    g = guild_list(c["Lara"])
    assert g["members"] == [K("Rita")] and g["phase"] == 4 and g["by"] == K("Gina"), g
    assert c["Lara"].eval("return ns.Guild:GetGuildPhase()") == 4
    # 1.3: a list taken on trust (Lara had none; the relayer is on the list it relays) makes nobody council until the
    # GM confirms it: any member could seed a fresh client with a list naming themselves
    assert c["Lara"].eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is True
    assert council(c["Lara"], "Rita") is False and council(c["Lara"], "Gina") is True
    # the relay is answered once: a second query within 60 s from the same member gets no second copy
    mark = len(w.addon_log)
    send_as(c["Lara"], {"t": "CQ", "r": 0}, "WHISPER", K("Rita"))
    send_as(c["Lara"], {"t": "CQ", "r": 0}, "WHISPER", K("Rita"))
    w.tick(10)
    assert len([m for m in msgs(w, "CG", mark) if m["_sender"] == K("Rita")]) <= 1
    # the GM logs in: its HELLO (cg) makes Lara ask it, and the GM's own CG confirms the list
    c["Gina"].login()
    w.run_until(lambda: c["Lara"].eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is False, timeout=30)
    assert council(c["Lara"], "Rita") is True and guild_list(c["Lara"])["rev"] == rev
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def forged_and_implausible_council_lists_are_rejected():
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST"), ("Mal", 3, "ROGUE"), ("Sam", 3, "MAGE"),
                        ("Fresh", 3, "DRUID", False)])
    rev = gm_pick(w, c["Gina"], ["Rita"])

    def revs():
        return {n: c[n].eval("return ns.Guild:GetGuildCouncilRev()") for n in ("Gina", "Rita", "Mal", "Sam")}

    base = revs()
    assert set(base.values()) == {rev}, base
    # 1) a non-council member forges a newer list "by the GM" naming himself: nobody with a list takes it
    send_as(c["Mal"], {"t": "CG", "rev": rev + 5, "m": [K("Mal"), K("Rita")], "ph": 1, "by": K("Gina")}, "GUILD")
    w.tick(2)
    assert revs() == base, revs()
    for n in ("Gina", "Rita", "Sam"):
        assert council(c[n], "Mal") is False, n
    # 2) a council relayer, but `by` is not the current GM
    send_as(c["Rita"], {"t": "CG", "rev": rev + 6, "m": [K("Rita"), K("Sam")], "ph": 1, "by": K("Rita")}, "GUILD")
    w.tick(2)
    assert revs() == base, revs()
    # 3) implausible future revs are rejected, from a council relayer and from the GM itself
    far = now(c["Rita"]) + 1000
    send_as(c["Rita"], {"t": "CG", "rev": far, "m": [K("Rita"), K("Sam")], "ph": 1, "by": K("Gina")}, "GUILD")
    send_as(c["Gina"], {"t": "CG", "rev": far + 1, "m": [K("Rita"), K("Sam")], "ph": 1, "by": K("Gina")}, "GUILD")
    w.tick(2)
    assert revs() == base, revs()
    assert council(c["Sam"], "Sam") is False
    # 4) malformed lists: > 40 names, a name > 48 bytes, phase out of range, a non-list
    for bad in ({"m": ["N%02d-Thunderstrike" % i for i in range(41)], "ph": 1},
                {"m": ["X" * 49], "ph": 1}, {"m": [K("Sam")], "ph": 9}, {"m": K("Sam"), "ph": 1},
                {"m": [K("Sam")], "ph": 1, "rev": "soon"}):
        msg = {"t": "CG", "rev": rev + 7, "by": K("Gina")}
        msg.update(bad)
        send_as(c["Gina"], msg, "GUILD")
    w.tick(2)
    assert revs() == base, revs()
    # 5) an older rev from the GM never replaces a newer list
    send_as(c["Gina"], {"t": "CG", "rev": rev - 10, "m": [K("Mal")], "ph": 1, "by": K("Gina")}, "GUILD")
    w.tick(2)
    assert revs() == base and council(c["Sam"], "Mal") is False
    # 6) a relay by a council member of my list (by = the GM, a newer rev) is accepted: this is how the list travels
    send_as(c["Rita"], {"t": "CG", "rev": rev + 8, "m": [K("Rita"), K("Sam")], "ph": 2, "by": K("Gina")}, "GUILD")
    w.tick(2)
    for n in ("Mal", "Sam"):
        assert c[n].eval("return ns.Guild:GetGuildCouncilRev()") == rev + 8, n
        assert council(c[n], "Sam") is True, n
    # DisasterZone 0.5: the GM's own client never takes a relayed copy of "its" list (it may be forged); only its saves
    assert c["Gina"].eval("return ns.Guild:GetGuildCouncilRev()") == rev, "the GM took a relayed copy of its list"
    # 1.3: ... and the GM's own CG outranks a relayed copy whatever its rev. Sam, council under the relayed list, says
    # hello with the newer rev; the GM sees it and shares its own list again, which replaces every relayed copy.
    mark = len(w.addon_log)
    w.tick(12)
    reshare = [m for m in msgs(w, "CG", mark) if m["_sender"] == K("Gina") and m["_chat_type"] == "GUILD"]
    assert reshare and reshare[0]["rev"] == rev, [(m["_sender"], m["rev"]) for m in msgs(w, "CG", mark)]
    assert revs() == base, revs()
    for n in ("Mal", "Sam"):
        assert council(c[n], "Sam") is False, n
    # 7) trust on first use: a fresh client (no list) takes a relay only when the relayer is on the relayed list
    c["Fresh"].login()
    w.tick(3)
    send_as(c["Mal"], {"t": "CG", "rev": rev + 9, "m": [K("Rita")], "ph": 1, "by": K("Gina")}, "WHISPER", K("Fresh"))
    w.tick(2)
    fresh_rev = c["Fresh"].eval("return ns.Guild:GetGuildCouncilRev()")
    assert fresh_rev in (0, rev), "a relayer that is not on its relayed list was trusted (%s)" % fresh_rev
    assert council(c["Fresh"], "Mal") is False
    no_errors(w)
    # a fresh client with only Mal's forged self-listing list: TOFU stores it, but (1.3) an unconfirmed list makes
    # nobody council; the GM's HELLO after its login makes the client ask the GM, whose own list replaces it
    w2, d = guild_world([("Gina", 0, "PALADIN"), ("Mal", 3, "ROGUE"), ("New", 3, "DRUID", False)])
    gm_rev = gm_pick(w2, d["Gina"], [])
    d["Gina"].logout()
    d["New"].login()
    w2.tick(3)
    t = now(d["Mal"])
    send_as(d["Mal"], {"t": "CG", "rev": t, "m": [K("Mal")], "ph": 1, "by": K("Gina")}, "WHISPER", K("New"))
    w2.tick(2)
    assert d["New"].eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is True
    assert council(d["New"], "Mal") is False, "an unconfirmed (TOFU) list must not make its relayer council"
    assert d["New"].eval("return #ns.Guild:GetCouncilMembers()") == 1, "only the GM is council on the fresh client"
    w2.tick(5)
    d["Gina"].login()
    w2.run_until(lambda: d["New"].eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is False, timeout=30)
    assert guild_list(d["New"])["rev"] == gm_rev and guild_list(d["New"])["members"] == []
    gm_pick(w2, d["Gina"], ["New"])
    assert council(d["New"], "Mal") is False and council(d["New"], "New") is True
    assert council(d["Mal"], "Mal") is False, "Mal's own client must not take its forged list as the GM's"
    no_errors(w2)


@case
def gm_removes_a_member_who_loses_council_views_and_whisper_gates_everywhere():
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST"), ("Sam", 3, "MAGE"), ("Tess", 3, "DRUID")])
    gm_pick(w, c["Gina"], ["Rita", "Sam"])
    open_window(c["Sam"])
    c["Sam"].slash("/dz council")
    w.tick(0.5)
    assert c["Sam"].eval("return ns.MainFrame:GetSelectedTab()") == "council"
    award = lambda i: {"id": "m%dSam%d" % (now(c["Sam"]), i), "i": i, "w": K("Tess"), "b": "",  # noqa: E731
                       "ts": now(c["Sam"]), "by": K("Sam"), "s": "m"}
    # control: while Sam is council, his award whisper is merged by a council member
    a1 = award(28586)
    send_as(c["Sam"], {"t": "A", "e": a1}, "WHISPER", K("Rita"))
    w.tick(1)
    assert c["Rita"].eval("return ns.Ledger:GetEntry(...) ~= nil", a1["id"]) is True
    gm_pick(w, c["Gina"], ["Rita"])                     # the GM removes Sam
    for n in c:
        assert council(c[n], "Sam") is False, n
    assert tabs(c["Sam"]) == ["home", "mybis", "atlas", "raids", "dungeons", "events", "members", "games", "changelog", "settings"], tabs(c["Sam"])
    assert c["Sam"].eval("return ns.MainFrame:GetSelectedTab()") == "home"
    a2 = award(28587)
    send_as(c["Sam"], {"t": "A", "e": a2}, "WHISPER", K("Rita"))
    send_as(c["Sam"], {"t": "A", "e": a2}, "WHISPER", K("Gina"))
    w.tick(1)
    for n in ("Rita", "Gina"):
        assert c[n].eval("return ns.Ledger:GetEntry(...) == nil", a2["id"]) is True, n
    assert_no_guild_info(c.values())
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# raid council (CR / CRQ)
# ------------------------------------------------------------------------------------------------------------------
def raid_world():
    # Lee: raid leader, a plain member (not on the guild list); Gina: GM; Out: guild member outside the raid.
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"),
                        ("Tess", 3, "DRUID"), ("Out", 3, "MAGE")])
    gm_pick(w, c["Gina"], [])
    return w, c


@case
def raid_leader_picks_raiders_who_are_council_only_inside_that_raid():
    w, c = raid_world()
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Tess"], c["Gina"]], leader=c["Lee"])
    w.tick(5)
    for n in ("Rita", "Sam", "Tess", "Gina"):
        assert council(c[n], "Lee") is True and source(c[n], "Lee") == "raidleader", n
    assert council(c["Out"], "Lee") is False, "the raid leader is council for their raid only"
    mark = len(w.addon_log)
    raid_pick(w, c["Lee"], ["Rita", "Sam"])
    cr = msgs(w, "CR", mark)
    assert len(cr) == 1 and cr[0]["_chat_type"] == "RAID" and sorted(cr[0]["m"]) == [K("Rita"), K("Sam")], cr
    for n in ("Lee", "Rita", "Sam", "Tess", "Gina"):
        for m in ("Rita", "Sam"):
            assert council(c[n], m) is True and source(c[n], m) == "raid", (n, m)
        assert council(c[n], "Tess") is False, n
        rl = raid_list(c[n])
        assert rl and rl["leader"] == K("Lee") and rl["members"] == [K("Rita"), K("Sam")], (n, rl)
    for m in ("Lee", "Rita", "Sam"):
        assert council(c["Out"], m) is False, "a guild member outside the raid must not see raid council (%s)" % m
    assert c["Out"].eval("return ns.Guild:GetRaidCouncil()") is None
    # whisper gates: accepted by council clients in the same raid, rejected outside it
    t = now(c["Rita"])
    a = {"id": "m%dRita28588" % t, "i": 28588, "w": K("Tess"), "b": "", "ts": t, "by": K("Rita"), "s": "m"}
    send_as(c["Rita"], {"t": "A", "e": a}, "WHISPER", K("Gina"))
    w.tick(1)
    assert c["Gina"].eval("return ns.Ledger:GetEntry(...) ~= nil", a["id"]) is True, "raid council -> GM in the raid"
    gm_pick(w, c["Gina"], ["Out"])                      # Out is guild council now, but not in the raid
    send_as(c["Rita"], {"t": "A", "e": dict(a, id=a["id"] + "x")}, "WHISPER", K("Out"))
    w.tick(1)
    assert c["Out"].eval("return ns.Ledger:GetEntry(...) == nil", a["id"] + "x") is True, "raid scope leaked outside"
    # a raid member who is not the leader cannot pick (only the leader's CR counts)
    send_as(c["Tess"], {"t": "CR", "rev": t + 5, "m": [K("Tess")]}, "RAID", None, "alert")
    w.tick(1)
    for n in ("Lee", "Rita", "Sam", "Gina"):
        assert council(c[n], "Tess") is False, "%s accepted a CR from a non-leader" % n
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def raid_scope_council_shares_awards_of_the_raid_but_never_gets_the_guild_award_log():
    w, c = raid_world()
    gm_pick(w, c["Gina"], ["Sam"])                      # Sam: guild council (control)
    old = c["Gina"].eval_py("return ns.Ledger:Award(28477, 'Out-Thunderstrike', 'Karazhan:Attumen', 'last week')")
    assert old and old.get("id"), old
    w.tick(2)
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Gina"]], leader=c["Lee"])
    w.tick(5)
    raid_pick(w, c["Lee"], ["Rita"])
    assert council(c["Gina"], "Rita") is True and source(c["Gina"], "Rita") == "raid"
    day = now(c["Gina"]) // 86400
    mark = len(w.addon_log)
    send_as(c["Rita"], {"t": "LW", "d": [day]}, "WHISPER", K("Gina"))
    send_as(c["Lee"], {"t": "LW", "d": [day]}, "WHISPER", K("Gina"))
    w.tick(4)
    # (a guild council member such as Sam may get an LG from an unrelated ledger sync in this window: only LGs to the
    # raid-scope members count)
    lg = [e for e in w.addon_log[mark:] if e["prefix"].startswith("CDL") and e["target"] in ("Rita", "Lee", K("Rita"), K("Lee"))
          and (lr.decode_msg(c["Gina"], e["text"]) or {}).get("t") == "LG"]
    assert not lg, "the guild's award log was sent to raid-scope council: %s" % [(e["sender"], e["target"]) for e in lg]
    assert c["Rita"].eval("return ns.Ledger:GetEntry(...) == nil", old["id"]) is True
    # control: a guild council member gets it
    send_as(c["Sam"], {"t": "LW", "d": [day]}, "WHISPER", K("Gina"))
    w.tick(4)
    assert msgs(w, "LG", mark), "no LG for a guild council member"
    assert c["Sam"].eval("return ns.Ledger:GetEntry(...) ~= nil", old["id"]) is True
    no_errors(w)


@case
def disband_clears_new_raid_reshares_and_leader_change_switches_lists():
    w, c = raid_world()
    raiders = [c["Lee"], c["Rita"], c["Sam"], c["Tess"], c["Gina"]]
    w.make_raid(raiders, leader=c["Lee"])
    w.tick(5)
    raid_pick(w, c["Lee"], ["Rita", "Sam"])
    raid_pick(w, c["Tess"], ["Gina"], tick=0)           # Tess's own list for when she leads ("until changed")
    w.tick(1)
    assert council(c["Rita"], "Gina") is True           # the GM, not because of Tess's (unshared) list
    assert council(c["Sam"], "Rita") is True
    # disband: cleared everywhere, the leader keeps the list "until changed"
    w.disband()
    w.tick(2)
    for n in ("Lee", "Rita", "Sam", "Tess"):
        for m in ("Rita", "Sam", "Lee"):
            assert council(c[n], m) is False, (n, m)
        assert c[n].eval("return ns.Guild:GetRaidCouncil()") is None, n
    assert c["Lee"].eval_py("return ns.Guild:GetMyRaidList()")["members"].keys() >= {K("Rita"), K("Sam")}
    # the same leader forms a new raid: the list is re-shared automatically
    mark = len(w.addon_log)
    w.make_raid(raiders, leader=c["Lee"])
    w.tick(6)
    assert [m for m in msgs(w, "CR", mark) if m["_sender"] == K("Lee")], "no automatic CR for the new raid"
    for n in ("Rita", "Sam", "Tess", "Gina"):
        assert council(c[n], "Rita") is True and council(c[n], "Sam") is True, n
    # the lead changes mid-raid: Tess's list applies, Lee's picks and Lee lose raid council status
    w.make_raid([c["Tess"], c["Lee"], c["Rita"], c["Sam"], c["Gina"]], leader=c["Tess"])
    for x in raiders:
        x.fire("PARTY_LEADER_CHANGED")
    w.tick(8)
    for n in ("Lee", "Rita", "Sam", "Gina"):
        rl = raid_list(c[n])
        assert rl and rl["leader"] == K("Tess") and rl["members"] == [K("Gina")], (n, rl)
        assert council(c[n], "Tess") is True and council(c[n], "Rita") is False and council(c[n], "Lee") is False, n
    # ... and a new leader without a list: only the leader
    w.make_raid([c["Sam"], c["Lee"], c["Rita"], c["Tess"], c["Gina"]], leader=c["Sam"])
    for x in raiders:
        x.fire("PARTY_LEADER_CHANGED")
    w.tick(8)
    for n in ("Lee", "Rita", "Tess"):
        rl = raid_list(c[n])
        assert rl is None or rl["members"] == [], (n, rl)
        assert council(c[n], "Sam") is True and council(c[n], "Tess") is False, n
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def raid_leader_is_council_for_their_raid_and_loses_the_tab_after_leaving():
    w, c = raid_world()
    open_window(c["Lee"])
    assert tabs(c["Lee"]) == ["home", "mybis", "atlas", "raids", "dungeons", "events", "members", "games", "changelog", "settings"]
    w.make_raid([c["Lee"], c["Rita"], c["Sam"]], leader=c["Lee"])
    w.tick(5)
    assert council(c["Lee"]) is True and c["Lee"].eval("return ns.Guild:AmIRaidLeader()") is True
    assert tabs(c["Lee"]) == ["home", "mybis", "atlas", "council", "raids", "dungeons", "events", "members", "games", "changelog", "settings"], tabs(c["Lee"])
    assert tabs(c["Rita"]) == ["home", "mybis", "atlas", "raids", "dungeons", "events", "members", "games", "changelog", "settings"] or not c["Rita"].eval("return ns.MainFrame:IsShown()")
    c["Lee"].slash("/dz council")
    w.tick(0.5)
    assert c["Lee"].eval("return ns.MainFrame:GetSelectedTab()") == "council"
    w.disband()
    w.tick(2)
    assert council(c["Lee"]) is False
    assert tabs(c["Lee"]) == ["home", "mybis", "atlas", "raids", "dungeons", "events", "members", "games", "changelog", "settings"], tabs(c["Lee"])
    assert c["Lee"].eval("return ns.MainFrame:GetSelectedTab()") == "home"
    # on the guild list too: the tab stays after the raid
    gm_pick(w, c["Gina"], ["Lee"])
    w.make_raid([c["Lee"], c["Rita"]], leader=c["Lee"])
    w.tick(4)
    w.disband()
    w.tick(2)
    assert tabs(c["Lee"]) == ["home", "mybis", "atlas", "council", "raids", "dungeons", "events", "members", "games", "changelog", "settings"], tabs(c["Lee"])
    no_errors(w)


@case
def joining_mid_raid_and_reload_get_the_raid_council_via_crq():
    w, c = raid_world()
    w.make_raid([c["Lee"], c["Rita"], c["Sam"]], leader=c["Lee"])
    w.tick(5)
    raid_pick(w, c["Lee"], ["Rita"])
    mark = len(w.addon_log)
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Tess"]], leader=c["Lee"])   # Tess joins
    w.tick(8)
    assert [m for m in msgs(w, "CRQ", mark) if m["_sender"] == K("Tess")], "no CRQ from the joining member"
    assert council(c["Tess"], "Rita") is True, "joining member did not get the raid council"
    mark = len(w.addon_log)
    c["Sam"].relog()
    install_helpers(c["Sam"])
    w.tick(1)
    assert council(c["Sam"], "Rita") is False, "the raid council is kept in memory only"
    w.tick(8)
    assert [m for m in msgs(w, "CRQ", mark) if m["_sender"] == K("Sam")], "no CRQ after the reload"
    assert council(c["Sam"], "Rita") is True, "reloaded member did not get the raid council back"
    # the leader reloads: the saved list is re-shared, nothing is lost
    c["Lee"].relog()
    w.tick(8)
    assert council(c["Lee"], "Rita") is True and council(c["Tess"], "Rita") is True
    no_errors(w)


@case
def pug_raid_leader_from_another_guild_is_never_council():
    # 1.3: pugs are never loot council. A raid leader outside my guild is not council, and its raid council list (CR)
    # is ignored, also for the members of my guild it names.
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST"), ("Out", 3, "MAGE")])
    pug = Client(w, "Pugger", guild="Other Guild", guild_rank=3, class_file="SHAMAN", preload_lua=GUILD_INFO_SPY)
    pug.load_addon()
    w.tick(3)
    w.make_raid([pug, c["Rita"], c["Gina"]], leader=pug)
    w.tick(5)
    raid_pick(w, pug, ["Rita"])
    for n in ("Rita", "Gina"):
        assert council(c[n], "Pugger") is False and source(c[n], "Pugger") is None, n
        assert council(c[n], "Rita") is False and source(c[n], "Rita") is None, n
        assert raid_list(c[n]) is None, (n, raid_list(c[n]))
        assert council(c[n], "Gina") is True, n          # the guild council stays council in the raid
    assert council(c["Out"], "Pugger") is False and council(c["Out"], "Rita") is False
    # (inside its own guild the pug leads a raid as usual: its own client sees itself as that raid's leader)
    assert source(pug, "Pugger") == "raidleader"
    # a raid leader of my guild picking a pug: the pug is not council either
    w.make_raid([c["Rita"], pug, c["Gina"]], leader=c["Rita"])
    w.tick(5)
    raid_pick(w, c["Rita"], ["Pugger", "Gina"])
    for n in ("Rita", "Gina"):
        assert source(c[n], "Rita") == "raidleader", n
        assert council(c[n], "Pugger") is False, n
        assert K("Pugger") not in (raid_list(c[n]) or {}).get("members", []), (n, raid_list(c[n]))
    assert_no_guild_info(list(c.values()) + [pug])
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# the picker UI
# ------------------------------------------------------------------------------------------------------------------
PICKER_HELP = r"""
function T_cv() return DisasterZoneCouncilPanel and DisasterZoneCouncilPanel.councilView end
function T_sec(kind) return T_cv()[kind] end
function T_shown_keys(kind)
  local out = {}
  for _, e in ipairs(T_sec(kind).picker:GetShown()) do
    out[#out + 1] = e.header and ("#" .. e.header) or (e.key .. (e.fixed and "!" or ""))
  end
  return out
end
function T_rows_keys(kind)
  local out = {}
  for _, d in ipairs(T_sec(kind).list:GetData()) do out[#out + 1] = d.key .. (d.fixed and "!" or "") .. (d.isNew and "+" or "") end
  return out
end
function T_count(set) local n = 0 for _ in pairs(set or {}) do n = n + 1 end return n end
"""


def open_picker(c):
    install_helpers(c)
    c.eval(PICKER_HELP)
    c.slash("/dz council")
    c.world.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council", "no Council tab for %s" % c.full_name
    c.eval("ns.CouncilUI:SetView('council')")
    c.world.tick(0.3)
    assert c.eval("return T_cv():IsVisible()") is True


@case
def searchable_dropdown_filters_toggles_saves_reverts_and_clears():
    w, c = guild_world([("Gm", 0, "WARRIOR"), ("Rai", 3, "HUNTER"), ("Ann", 1, "PRIEST"), ("Ben", 3, "MAGE")])
    w.add_offline_member("Bob", "MAGE", 3)
    w.add_offline_member("Carl", "ROGUE", 1)
    gm, rai = c["Gm"], c["Rai"]
    open_picker(gm)
    sec = "T_sec('guild')"
    assert gm.eval("return %s.picker.frame:IsShown()" % sec) is True
    assert gm.eval("return %s.save:IsEnabled()" % sec) is False, "Save & share before any change"
    status = strip_codes(gm.eval("return %s.status:GetText()" % sec))
    assert status.startswith("Not shared yet"), status
    eb = gm.eval("return %s.picker.editBox" % sec)
    # online members only, case-insensitive substring
    gm.type_text(eb, "a")
    assert gm.eval("return %s.picker:IsOpen()" % sec) is True
    assert gm.eval_py("return T_shown_keys('guild')") == [K("Ann"), K("Rai")]
    gm.type_text(eb, "RA")
    assert gm.eval_py("return T_shown_keys('guild')") == [K("Rai")]
    gm.type_text(eb, "zzz")
    assert gm.eval_py("return T_shown_keys('guild')") == []
    gm.type_text(eb, "ra")
    gm.press_enter(eb)                                 # toggles the top match into the draft
    d = gm.eval_py("return ns.CouncilUI:GetCouncilDraft('guild')")
    assert list(d["members"].keys()) == [K("Rai")] and d["dirty"] is True, d
    assert gm.eval("return %s.save:IsEnabled()" % sec) is True
    assert gm.eval_py("return T_rows_keys('guild')") == [K("Gm") + "!", K("Rai") + "+"]
    status = strip_codes(gm.eval("return %s.status:GetText()" % sec))
    assert status.startswith("Unsaved changes"), status
    gm.press_enter(eb)                                 # toggles it off again: back to the saved state
    assert gm.eval_py("return ns.CouncilUI:GetCouncilDraft('guild')")["dirty"] is False
    assert gm.eval("return %s.save:IsEnabled()" % sec) is False
    gm.press_enter(eb)
    # "Show offline members"
    gm.type_text(eb, "")
    gm.click(gm.eval("return %s.picker.toggleCheck" % sec))
    shown = gm.eval_py("return T_shown_keys('guild')")
    assert shown == [K("Ann"), K("Ben"), K("Bob"), K("Carl"), K("Gm") + "!", K("Rai")], shown
    gm.type_text(eb, "car")
    gm.press_enter(eb)
    gm.press_escape(eb)
    assert gm.eval("return %s.picker:IsOpen()" % sec) is False
    # the phase dropdown, then Save & share
    menu = gm.dropdown_menu(gm.eval("return %s.phaseDD" % sec))
    gm.menu_select([ch["text"] for ch in menu["children"]][1])
    p0 = len(gm.chat_frame)
    gm.click(gm.eval("return %s.save" % sec))
    w.tick(1)
    assert any("Guild council saved and shared" in l for l in printed_since(gm, p0)), printed_since(gm, p0)
    assert strip_codes(gm.eval("return %s.status:GetText()" % sec)).startswith("Shared just now")
    assert gm.eval("return %s.save:IsEnabled()" % sec) is False
    assert sorted(guild_list(rai)["members"]) == [K("Carl"), K("Rai")] and guild_list(rai)["phase"] == 2
    # Revert discards a draft change; the row "x" removes from the draft
    gm.eval("ns.CouncilUI:ToggleCouncilDraft('guild', ...)", K("Ben"))
    assert gm.eval("return %s.revert:IsEnabled()" % sec) is True
    gm.click(gm.eval("return %s.revert" % sec))
    assert gm.eval_py("return ns.CouncilUI:GetCouncilDraft('guild')")["dirty"] is False
    n_rows = gm.eval("return #T_rows(%s.list.box)" % sec)
    assert n_rows == 3, n_rows
    gm.click(gm.eval("return T_rows(%s.list.box)[2].remove" % sec))
    assert gm.eval_py("return ns.CouncilUI:GetCouncilDraft('guild')")["dirty"] is True
    gm.click(gm.eval("return %s.revert" % sec))
    # Clear list asks first; cancel keeps, accept saves + shares an empty list (the phase stays)
    gm.click(gm.eval("return %s.clear" % sec))
    assert "DISASTERZONE_CLEAR_COUNCIL" in gm.popups()
    gm.cancel_popup("DISASTERZONE_CLEAR_COUNCIL")
    w.tick(1)
    assert len(guild_list(rai)["members"]) == 2
    gm.click(gm.eval("return %s.clear" % sec))
    gm.accept_popup("DISASTERZONE_CLEAR_COUNCIL")
    w.tick(1)
    assert guild_list(rai)["members"] == [] and guild_list(rai)["phase"] == 2
    assert council(rai) is False
    # the raid section: not in a raid -> nothing to edit for the GM
    assert gm.eval("return T_sec('raid').picker.frame:IsShown()") is False
    # a non-GM council member sees the guild list read-only
    gm_pick(w, gm, ["Rai"])
    open_picker(rai)
    assert rai.eval("return T_sec('guild').picker.frame:IsShown()") is False
    assert rai.eval("return ns.CouncilUI:CanEditCouncil('guild')") is False
    assert_no_guild_info(c.values())
    no_errors(w)


@case
def settings_edit_council_button_follows_what_it_opens():
    # 1.3 audit: Settings' "Edit council..." and its "You can edit ..." line follow what the Council tab really opens.
    # A plain raider who once led a raid keeps a saved raid list, but has no Council tab: no button, no such line.
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "MAGE")])
    gm_pick(w, c["Gina"], ["Rita"])
    for leader in ("Lee", "Rita"):
        w.make_raid([c[leader], c["Sam"]], leader=c[leader])
        w.tick(5)
        raid_pick(w, c[leader], ["Sam"])
        w.disband()
        w.tick(3)

    def settings(cl):
        open_window(cl)
        cl.eval("ns.MainFrame:Open('settings')")
        w.tick(0.5)
        return (cl.eval("return ns.SettingsUI.cs.editBtn:IsShown()"),
                strip_codes(cl.eval("return ns.SettingsUI.cs.info:GetText()") or ""))

    assert c["Lee"].eval_py("return ns.Guild:GetMyRaidList() ~= nil") is True
    shown, info = settings(c["Lee"])
    assert shown is False and "You can edit" not in info, (shown, info)
    shown, info = settings(c["Rita"])
    assert shown is True and info == "You can edit your raid council list (used whenever you lead a raid).", (shown, info)
    c["Rita"].click(c["Rita"].eval("return ns.SettingsUI.cs.editBtn"))
    w.tick(0.5)
    assert c["Rita"].eval("return ns.MainFrame:GetSelectedTab()") == "council"
    shown, info = settings(c["Gina"])
    assert shown is True and info == "You can edit the guild council (Guild Master).", (shown, info)
    no_errors(w)


@case
def raid_leader_picker_lists_raid_members_first():
    w, c = guild_world([("Gm", 0, "WARRIOR"), ("Ann", 3, "PRIEST"), ("Rai", 3, "HUNTER"), ("Zed", 3, "ROGUE")])
    ann, rai = c["Ann"], c["Rai"]
    w.make_raid([ann, rai], leader=ann)
    w.tick(5)
    open_picker(ann)
    assert ann.eval("return T_sec('raid').picker.frame:IsShown()") is True
    assert ann.eval("return T_sec('guild').picker.frame:IsShown()") is False, "only the GM edits the guild list"
    eb = ann.eval("return T_sec('raid').picker.editBox")
    ann.type_text(eb, "")
    shown = ann.eval_py("return T_shown_keys('raid')")
    assert shown[:3] == ["#In your raid", K("Ann") + "!", K("Rai")], shown
    assert K("Zed") in shown and shown.index(K("Zed")) > shown.index(K("Rai")), shown
    assert ann.eval("return T_sec('raid').save:IsEnabled()") is False
    ann.type_text(eb, "rai")
    ann.press_enter(eb)
    ann.click(ann.eval("return T_sec('raid').save"))
    w.tick(1)
    st = strip_codes(ann.eval("return T_sec('raid').status:GetText()"))
    assert st.startswith("Shared with this raid"), st
    assert council(rai, "Rai") is True and council(c["Zed"], "Rai") is False
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# migration + Guild Information
# ------------------------------------------------------------------------------------------------------------------
OLD_DB = """{ schema = 1, settings = { viewPhase = 2 },
  guildCfg = { raw = "CDL{r1 p3 +Rai}", rank = 1, phase = 3, add = { ["Rai-Thunderstrike"] = true }, remove = {},
               guild = "Casual Disaster-Thunderstrike", fetchedAt = 1789990000 },
  guildInfoSeen = { ["Casual Disaster-Thunderstrike"] = true },
  guildInfoBackups = { { text = "Welcome\\nCDL{r1 p3 +Rai}", at = 1789990000, by = "Gm-Thunderstrike" } } }"""
NOTICE = "DisasterZone no longer uses the Guild Information text. You can delete the CDL{...} line from your Guild Info."


@case
def migration_drops_the_guild_info_cache_and_prints_the_notice_once():
    w = World()
    w.set_guild_info_text("Welcome\nCDL{r1 p3 +Rai}")        # the old tag is still in the Guild Info
    rai = Client(w, "Rai", guild_rank=3, preload_lua=GUILD_INFO_SPY)
    rai.set_saved_variable("DisasterZoneDB", OLD_DB)
    rai.load_addon()
    w.tick(3)
    db = rai.eval_py("return DisasterZoneDB")
    for k in ("guildCfg", "guildInfoSeen", "guildInfoBackups"):
        assert k not in db, "%s survived the migration" % k
    assert db["settings"].get("viewPhase") == 2, "other saved data must be kept"
    lines = [strip_codes(l) for l in rai.chat_frame]
    assert sum(1 for l in lines if NOTICE in l) == 1, lines
    # the old tag has no effect any more: Rai is not council, the tag's phase is not used
    assert council(rai) is False
    assert rai.eval("return ns.Guild:GetGuildPhase()") == 1
    rai.relog()
    w.tick(3)
    lines = [strip_codes(l) for l in rai.chat_frame]
    assert sum(1 for l in lines if NOTICE in l) == 1, "the notice must print once only"
    # a cache without a tag is dropped silently
    w2 = World()
    c2 = Client(w2, "Cee", guild_rank=3)
    c2.set_saved_variable("DisasterZoneDB", '{ schema = 1, guildCfg = { raw = "", fetchedAt = 1 }, guildInfoSeen = {} }')
    c2.load_addon()
    w2.tick(3)
    assert "guildCfg" not in c2.eval_py("return DisasterZoneDB")
    assert not any(NOTICE in strip_codes(l) for l in c2.chat_frame)
    assert w.guild_info_text() == "Welcome\nCDL{r1 p3 +Rai}", "the Guild Info must not be touched"
    assert_no_guild_info([rai])
    no_errors(w)
    no_errors(w2)


GI_API = ("C_GuildInfo.GetInfoText", "C_GuildInfo.SetInfoText", "GetGuildInfoText", "SetGuildInfoText")


@case
def guild_info_api_is_never_called():
    """Spy on every Guild Information text API in each client through a session that exercises the council code:
    login, roster updates, the GM saving, relays, a raid with a raid list, Settings, the Council tab and picker,
    slash commands, relogs. Also a static scan: no addon file (outside Libs) mentions these APIs."""
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Rita", 3, "PRIEST"), ("Olaf", 1, "MAGE"), ("Lara", 3, "DRUID", False)])
    w.set_guild_info_text("Raid nights Wed/Sun\nCDL{r1 p1}")
    gm_pick(w, c["Gina"], ["Rita"], phase=2)
    for x in (c["Gina"], c["Rita"], c["Olaf"]):
        install_helpers(x)
        for cmd in ("/dz", "/dz council", "/dz settings", "/dz log", "/dz rules", "/dz version", "/dz sync"):
            x.slash(cmd)
            w.tick(0.3)
    c["Gina"].eval("ns.CouncilUI:SetView('council')")
    c["Gina"].eval("ns.SettingsUI:Refresh()")
    w.make_raid([c["Olaf"], c["Rita"], c["Gina"]], leader=c["Olaf"])
    w.tick(5)
    raid_pick(w, c["Olaf"], ["Rita"])
    c["Lara"].login()
    w.tick(45)
    for x in (c["Gina"], c["Rita"]):
        x.fire("GUILD_ROSTER_UPDATE", True)
        x.relog()
    w.tick(10)
    w.disband()
    w.tick(3)
    for x in c.values():
        assert guild_info_calls(x) == [], "%s: %s" % (x.full_name, guild_info_calls(x))
    assert w.guild_info_text() == "Raid nights Wed/Sun\nCDL{r1 p1}"
    # the spy works (control): calling the API from the test is recorded
    c["Rita"].eval("C_GuildInfo.GetInfoText(); GetGuildInfoText()")
    assert set(guild_info_calls(c["Rita"])) == {"C_GuildInfo.GetInfoText", "GetGuildInfoText"}, guild_info_calls(c["Rita"])
    # static scan of the addon source
    pat = re.compile(r"GetInfoText|SetInfoText|GetGuildInfoText|SetGuildInfoText|CanEditGuildInfo")
    hits = []
    for root, dirs, files in os.walk(ADDON_DIR):
        dirs[:] = [d for d in dirs if d != "Libs"]
        for f in files:
            if f.endswith((".lua", ".xml", ".toc")):
                p = os.path.join(root, f)
                with open(p, encoding="utf-8", errors="replace") as fh:
                    for i, line in enumerate(fh, 1):
                        if pat.search(line):
                            hits.append("%s:%d: %s" % (os.path.relpath(p, ADDON_DIR), i, line.strip()))
    assert not hits, "Guild Info API referenced:\n" + "\n".join(hits)
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# sync
# ------------------------------------------------------------------------------------------------------------------
def commit_list(c, variant=0):
    items = c.eval_py("""
      local out = {}
      for _, r in ipairs(ns.ItemDB:GetCandidates(1, { maxPhase = 5, class = ... })) do
        if ns.ItemDB:FitsSlot(r.itemID, 1) then out[#out + 1] = r.itemID end
        if #out > 3 then break end
      end
      return out""", c.class_file)
    assert c.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", items[variant])
    c.eval("ns.BiS:Commit()")
    return c.eval("return ns.BiS:GetRecord().rev")


def cached_rev(c, name):
    return c.eval("local r = ns.Store:GetCached(...); return r and r.rev or 0", K(name))


@case
def picked_members_receive_lists_raid_scope_only_raid_members():
    w, c = guild_world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"),
                        ("Out", 3, "MAGE"), ("Gus", 3, "HUNTER")])
    gm_pick(w, c["Gina"], [])
    w.tick(40)                                          # login HELLO rate limits have passed
    revs = {n: commit_list(c[n]) for n in ("Lee", "Sam", "Out")}
    w.tick(10)
    assert cached_rev(c["Gina"], "Out") == revs["Out"], "the GM (council) receives everyone's lists"
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Gina"]], leader=c["Lee"])
    w.tick(5)
    assert cached_rev(c["Rita"], "Sam") == 0
    raid_pick(w, c["Lee"], ["Rita"])                    # Rita: raid-scope council
    w.tick(45)
    assert council(c["Rita"]) is True
    assert cached_rev(c["Rita"], "Sam") == revs["Sam"], "raid council member lacks a raid member's list"
    assert cached_rev(c["Rita"], "Lee") == revs["Lee"], "raid council member lacks the raid leader's list"
    assert cached_rev(c["Rita"], "Out") == 0, "a raid-scope council member got a list from outside the raid"
    # guild-list council receives everyone's lists (the promotion HELLO path)
    gm_pick(w, c["Gina"], ["Gus"])
    w.tick(45)
    for n in ("Lee", "Sam", "Out"):
        assert cached_rev(c["Gus"], n) == revs[n], "guild council member lacks %s's list" % n
    no_errors(w)


if __name__ == "__main__":
    run_all()
