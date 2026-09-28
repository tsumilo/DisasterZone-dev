#!/usr/bin/env python
"""Addendum D §28 (leader-controlled group loot rules), adjusted by Addendum E §32/§33, on the real addon.

The group's loot authority (E §33): in a raid the raid leader (always council for their raid), else the master
looter; in a party the party leader if council (GM / guild list) or if they turned dungeon mode on, else a guild-
list council member in the party (lowest rank index, then name). Only members running CDLoot with group rules
count (they sent GS / GQ). The authority shares roll duration (rd), drop quality (q), dungeon mode (dm, parties)
+ 5-man quality (dq) and the phase (ph, E §32) in GS on the group channel; everyone reads them through
ns.DB:GetEffective, the Settings controls go read-only ("Set by <Name> for this group").

Cases: a raid leader's rules reach every raider (Settings read-only); a change reaches the raid and the next roll
uses it (coalesced to one GS per 5 s); raid leader vs master looter (the leader wins, the ML takes over when the
leader has no CDLoot, no authority without both); GQ after joining / reload; forged and out-of-range GS rejected;
the leader leaves -> the next authority or personal values; party dungeon mode and the party eligibility order;
disband -> personal values; the phase rule; /cdl rules; mixed with CDLoot 0.2 clients (no errors, DM compat).

Every case ends with world.assert_no_errors(). Standalone; prints PASS/FAIL per case, exit code 1 on a failure.
Run: luaenv\\Scripts\\python.exe tests\\grouprules\\test_grouprules.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))

from _common import (case, run_all, no_errors, World, Client, ExtraMember, install_helpers, printed_since,  # noqa: E402
                     strip_codes, gm_pick)
import lr_common as lr  # noqa: E402

REALM = "Thunderstrike"
ADDON_02 = os.path.join(HERE, "addon02", "CDLoot")      # a CDLoot 0.2.0 copy (no group rules, no GS / GQ)
MINDBLADE = 28770


def K(name):
    return name if "-" in name else "%s-%s" % (name, REALM)


# ------------------------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------------------------
def world(specs, council=(), tick=3):
    """specs: [(name, rank, class)] or (name, rank, class, {client kw}); the first rank-0 client (if any) picks the
    guild council list `council`."""
    w = World()
    cs = {}
    for sp in specs:
        kw = dict(sp[3]) if len(sp) > 3 else {}
        cs[sp[0]] = Client(w, sp[0], guild_rank=sp[1], class_file=sp[2], **kw)
    for c in cs.values():
        c.load_addon()
    w.tick(tick)
    gm = next((c for n, c in cs.items() if c.guild_rank == 0), None)
    if gm is not None:
        gm_pick(w, gm, list(council))
    return w, cs


def eff(c, path):
    return c.eval("return ns.DB:GetEffective(...)", path)


def own(c, path):
    return c.eval("return ns.DB:GetSetting(...)", path)


def status(c):
    return c.eval_py("local s, f = ns.GroupRules:GetStatus(); return { s, f or false }")


def authority(c):
    return c.eval("return ns.GroupRules:GetAuthority()")


def gs_from(w, name, start=0):
    return [m for m in lr.msgs_of_type(w, "GS", start) if m["_sender"] == K(name)]


def gq_from(w, name, start=0):
    return [m for m in lr.msgs_of_type(w, "GQ", start) if m["_sender"] == K(name)]


def send_as(c, msg, dist, target=None, cls="alert"):
    return c.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", msg, dist, target, cls)


def set_(c, path, value):
    c.eval("ns.DB:SetSetting(...)", path, value)


def open_settings(c):
    install_helpers(c)
    c.slash("/cdl settings")
    c.world.tick(0.5)
    c.eval("ns.SettingsUI:Refresh()")


def rules_status_text(c):
    c.eval("ns.SettingsUI:Refresh()")
    return strip_codes(c.eval("return ns.SettingsUI.rulesStatus:GetText()"))


def controls_enabled(c):
    return c.eval_py("local o = {} for i, x in ipairs(ns.SettingsUI.ruleControls) do o[i] = x:IsEnabled() and 1 or 0 end "
                     "return o")


def roll_duration_sent(w, name, start):
    rs = [m for m in lr.msgs_of_type(w, "RS", start) if m["_sender"] == K(name)]
    return [m["d"] for m in rs]


# ------------------------------------------------------------------------------------------------------------------
# raid
# ------------------------------------------------------------------------------------------------------------------
@case
def raid_leaders_rules_reach_every_raider_and_settings_go_read_only():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 3, "MAGE"), ("Rita", 3, "PRIEST"),
                  ("Sam", 3, "ROGUE")], council=["Bob"])
    set_(c["Lee"], "roll.duration", 45)
    set_(c["Lee"], "qualityThreshold", 3)
    set_(c["Bob"], "roll.duration", 20)                 # a guild council member's own values do not matter
    mark = len(w.addon_log)
    w.make_raid([c["Lee"], c["Bob"], c["Rita"], c["Sam"], c["Gina"]], leader=c["Lee"])
    w.tick(6)
    gs = gs_from(w, "Lee", mark)
    assert gs and gs[0]["_chat_type"] == "RAID" and gs[0]["rd"] == 45 and gs[0]["q"] == 3, gs
    assert "dm" not in gs[0], "dungeon mode is a party rule"
    assert status(c["Lee"]) == ["mine", K("Lee")]
    for n in ("Bob", "Rita", "Sam", "Gina"):
        assert authority(c[n]) == K("Lee"), n
        assert status(c[n]) == ["remote", K("Lee")], (n, status(c[n]))
        assert eff(c[n], "roll.duration") == 45 and eff(c[n], "qualityThreshold") == 3, n
        active = c[n].eval_py("return ns.GroupRules:GetActive()")
        assert active["from"] == K("Lee") and active["values"]["rd"] == 45, active
        lines = [strip_codes(l) for l in c[n].chat_frame]
        assert sum(1 for l in lines if "loot rules set by Lee (rolls 45s, rares+" in l) == 1, lines[-3:]
    assert own(c["Bob"], "roll.duration") == 20 and own(c["Rita"], "roll.duration") == 30, "personal values kept"
    # Settings: "Set by Lee", the group-rule controls read-only and showing the group's values
    open_settings(c["Rita"])
    assert rules_status_text(c["Rita"]).startswith("Set by Lee for this group"), rules_status_text(c["Rita"])
    assert controls_enabled(c["Rita"]) == [0, 0, 0, 0], controls_enabled(c["Rita"])
    c["Rita"].eval("ns.SettingsUI.ruleControls[1]:GenerateMenu()")
    assert c["Rita"].eval("return ns.SettingsUI.ruleControls[1]:GetText()") == "45 seconds"
    open_settings(c["Lee"])
    assert rules_status_text(c["Lee"]).startswith("You set these for your group")
    assert controls_enabled(c["Lee"]) == [1, 1, 1, 1]
    no_errors(w)


@case
def leader_changes_the_duration_raiders_update_and_the_next_roll_uses_it():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 3, "MAGE"), ("Rita", 3, "PRIEST")],
                 council=["Bob"])
    w.make_raid([c["Lee"], c["Bob"], c["Rita"], c["Gina"]], leader=c["Lee"])
    w.tick(8)
    assert eff(c["Rita"], "roll.duration") == 30
    # the leader changes it through the Settings dropdown
    open_settings(c["Lee"])
    mark = len(w.addon_log)
    c["Lee"].dropdown_menu(c["Lee"].eval("return ns.SettingsUI.ruleControls[1]"))
    c["Lee"].menu_select("60 seconds")
    w.tick(1)
    assert own(c["Lee"], "roll.duration") == 60
    for n in ("Bob", "Rita", "Gina"):
        assert eff(c[n], "roll.duration") == 60, n
    # quick changes are coalesced: at most one GS per 5 s, the last value wins
    t0 = w.now
    set_(c["Lee"], "roll.duration", 20)
    w.tick(0.5)
    set_(c["Lee"], "roll.duration", 45)
    w.tick(0.5)
    set_(c["Lee"], "qualityThreshold", 3)
    w.tick(6)
    gs = gs_from(w, "Lee", mark)
    times = [m["_time"] for m in gs]
    assert all(b - a >= 4.9 for a, b in zip(times, times[1:])), times
    assert gs[-1]["rd"] == 45 and gs[-1]["q"] == 3, gs[-1]
    assert len([t for t in times if t >= t0]) <= 2, times
    for n in ("Bob", "Rita"):
        assert eff(c[n], "roll.duration") == 45 and eff(c[n], "qualityThreshold") == 3, n
    # the next roll uses the group's duration, also when a council member who is not the authority starts it
    mark = len(w.addon_log)
    assert c["Bob"].eval("return ns.Roll:Start(...) ~= nil", MINDBLADE) is True
    w.tick(1)
    assert roll_duration_sent(w, "Bob", mark) == [45], roll_duration_sent(w, "Bob", mark)
    sid = c["Bob"].eval("return ns.Roll:GetActive().id")
    assert c["Rita"].eval("return ns.Roll:Get(...).duration", sid) == 45
    no_errors(w)


@case
def raid_leader_wins_over_the_master_looter_who_takes_over_without_a_leader_with_cdloot():
    # Both run CDLoot: the raid leader (not on any list) is the authority, the master looter's GS is ignored.
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Mia", 3, "MAGE"), ("Rita", 3, "PRIEST")])
    set_(c["Lee"], "roll.duration", 45)
    set_(c["Mia"], "roll.duration", 15)
    w.make_raid([c["Lee"], c["Mia"], c["Rita"]], leader=c["Lee"], master_looter=c["Mia"])
    w.tick(10)
    for n in ("Mia", "Rita"):
        assert authority(c[n]) == K("Lee"), (n, authority(c[n]))
    assert eff(c["Rita"], "roll.duration") == 45 and eff(c["Mia"], "roll.duration") == 45
    assert c["Mia"].eval("return ns.GroupRules:IsAuthority()") is False
    send_as(c["Mia"], {"t": "GS", "v": 50, "rd": 15, "q": 4, "dq": 3}, "RAID")
    w.tick(1)
    assert eff(c["Rita"], "roll.duration") == 45, "the ML's GS must not override the raid leader's rules"
    no_errors(w)
    # the raid leader has no CDLoot: the master looter (not council) is the authority
    w2, d = world([("Gina", 0, "PALADIN"), ("Mia", 3, "MAGE"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE")])
    zed = ExtraMember("Zed", "WARRIOR", guild="Casual Disaster", guild_rank=3)
    w2.offline_members.append(zed)
    set_(d["Mia"], "roll.duration", 20)
    w2.make_raid([d["Mia"], d["Rita"], d["Sam"]], leader=zed, extra_members=[zed], master_looter=d["Mia"])
    w2.tick(12)
    for n in ("Rita", "Sam"):
        assert authority(d[n]) == K("Mia"), (n, authority(d[n]))
        assert eff(d[n], "roll.duration") == 20, n
        assert d[n].eval("return ns.Guild:IsCouncil(...)", K("Zed")) is True, "the raid leader is council (E §29)"
    assert status(d["Mia"])[0] == "mine"
    # group loot, leader without CDLoot: no authority, personal values
    w2.make_raid([d["Mia"], d["Rita"], d["Sam"]], leader=zed, extra_members=[zed])
    for x in d.values():
        x.fire("PARTY_LOOT_METHOD_CHANGED")
    w2.tick(3)
    for n in ("Mia", "Rita", "Sam"):
        assert authority(d[n]) is None, (n, authority(d[n]))
        assert status(d[n])[0] == "own", n
    assert eff(d["Rita"], "roll.duration") == 30 and eff(d["Mia"], "roll.duration") == 20
    no_errors(w2)


@case
def raider_joining_mid_raid_and_a_reload_get_the_rules_via_gq():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"),
                  ("Tess", 3, "DRUID")])
    set_(c["Lee"], "roll.duration", 60)
    set_(c["Lee"], "groupPhase", 3)
    w.make_raid([c["Lee"], c["Rita"], c["Sam"]], leader=c["Lee"])
    w.tick(8)
    assert eff(c["Sam"], "roll.duration") == 60
    mark = len(w.addon_log)
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Tess"]], leader=c["Lee"])    # Tess joins
    w.tick(8)
    assert gq_from(w, "Tess", mark), "no GQ from the joining raider"
    assert gs_from(w, "Lee", mark), "the leader did not answer the GQ"
    assert eff(c["Tess"], "roll.duration") == 60 and eff(c["Tess"], "phase") == 3
    assert status(c["Tess"]) == ["remote", K("Lee")]
    mark = len(w.addon_log)
    c["Sam"].relog()
    w.tick(0.5)
    assert status(c["Sam"])[0] != "remote", "group rules are session-only"
    w.tick(8)
    assert gq_from(w, "Sam", mark), "no GQ after the reload"
    assert eff(c["Sam"], "roll.duration") == 60 and c["Sam"].eval("return ns.Guild:GetGuildPhase()") == 3
    # the leader reloads: announces again (rev restarts), everybody keeps the rules
    c["Lee"].relog()
    w.tick(8)
    for n in ("Rita", "Sam", "Tess"):
        assert eff(c[n], "roll.duration") == 60 and status(c[n]) == ["remote", K("Lee")], n
    no_errors(w)


@case
def forged_gs_from_an_ineligible_raider_and_out_of_range_values_are_rejected():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE")],
                 council=["Sam"])
    w.make_raid([c["Lee"], c["Rita"], c["Sam"], c["Gina"]], leader=c["Lee"])
    w.tick(8)

    def snap():
        return {n: (eff(c[n], "roll.duration"), eff(c[n], "qualityThreshold"), eff(c[n], "phase"))
                for n in ("Rita", "Sam", "Gina")}

    base = snap()
    assert all(v == (30, 4, 1) for v in base.values()), base
    # an ineligible raider, a guild council member who is not the authority, and the GM (not the leader)
    for who in ("Rita", "Sam", "Gina"):
        send_as(c[who], {"t": "GS", "v": 99, "rd": 60, "q": 3, "dq": 4, "ph": 5}, "RAID")
    w.tick(1)
    assert snap() == base, snap()
    # out-of-range / malformed values from the authority itself
    for bad in ({"rd": 25}, {"rd": "30"}, {"q": 5}, {"q": 2}, {"dq": 2}, {"dm": "yes"}, {"ph": 9}, {"ph": 0},
                {"v": -1}, {"rd": None}):
        msg = {"t": "GS", "v": 7, "rd": 60, "q": 3, "dq": 3, "ph": 2}
        for k, v in bad.items():
            if v is None:
                msg.pop(k, None)
            else:
                msg[k] = v
        send_as(c["Lee"], msg, "RAID")
    w.tick(14)                                          # the burst drains through the server's addon throttle
    assert snap() == base, snap()
    # a GS on another channel is not a group rule
    send_as(c["Lee"], {"t": "GS", "v": 8, "rd": 60, "q": 3, "dq": 3}, "GUILD")
    send_as(c["Lee"], {"t": "GS", "v": 8, "rd": 60, "q": 3, "dq": 3}, "WHISPER", K("Rita"))
    w.tick(1)
    assert snap() == base, snap()
    # the real thing is accepted
    w.tick(3)
    send_as(c["Lee"], {"t": "GS", "v": 9, "rd": 60, "q": 3, "dq": 3, "ph": 2}, "RAID")
    w.tick(3)
    assert all(v == (60, 3, 2) for v in snap().values()), snap()
    no_errors(w)


@case
def leader_leaves_the_next_eligible_authority_takes_over_or_personal_values():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Mia", 3, "MAGE"), ("Rita", 3, "PRIEST")])
    zed = ExtraMember("Zed", "WARRIOR", guild="Casual Disaster", guild_rank=3)
    w.offline_members.append(zed)
    set_(c["Lee"], "roll.duration", 45)
    set_(c["Mia"], "roll.duration", 20)
    w.make_raid([c["Lee"], c["Mia"], c["Rita"]], leader=c["Lee"], master_looter=c["Mia"])
    w.tick(10)
    assert eff(c["Rita"], "roll.duration") == 45
    # Lee leaves; the lead goes to Zed (no CDLoot): the master looter decides now
    w.make_raid([c["Mia"], c["Rita"]], leader=zed, extra_members=[zed], master_looter=c["Mia"])
    for x in (c["Lee"], c["Mia"], c["Rita"]):
        x.fire("PARTY_LEADER_CHANGED")
    w.tick(12)
    assert authority(c["Rita"]) == K("Mia"), authority(c["Rita"])
    assert eff(c["Rita"], "roll.duration") == 20
    assert status(c["Lee"])[0] == "own" and eff(c["Lee"], "roll.duration") == 45, "Lee is out of the group"
    # the master looter hands master loot back (group loot): nobody decides, personal values again
    w.set_master_looter(None)
    w.tick(3)
    assert authority(c["Rita"]) is None and status(c["Rita"])[0] == "own"
    assert eff(c["Rita"], "roll.duration") == 30
    no_errors(w)


@case
def disband_reverts_everyone_to_personal_values():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST")])
    set_(c["Lee"], "roll.duration", 60)
    set_(c["Lee"], "qualityThreshold", 3)
    set_(c["Lee"], "groupPhase", 4)
    w.make_raid([c["Lee"], c["Rita"]], leader=c["Lee"])
    w.tick(8)
    open_settings(c["Rita"])
    install_helpers(c["Rita"])
    c["Rita"].eval("__GRC = 0; ns:On('GROUP_RULES_CHANGED', function() __GRC = __GRC + 1 end)")
    assert eff(c["Rita"], "roll.duration") == 60 and c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 4
    w.disband()
    w.tick(3)
    assert c["Rita"].eval("return __GRC") >= 1, "GROUP_RULES_CHANGED did not fire"
    assert status(c["Rita"]) == ["own", False]
    assert c["Rita"].eval("return ns.GroupRules:GetActive()") is None
    assert eff(c["Rita"], "roll.duration") == 30 and eff(c["Rita"], "qualityThreshold") == 4
    assert c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 1
    assert rules_status_text(c["Rita"]) == "Your own settings (not in a group)"
    assert controls_enabled(c["Rita"]) == [1, 1, 1, 1]
    # the former authority keeps its own values (and its group phase stays a prepared setting)
    assert eff(c["Lee"], "roll.duration") == 60 and c["Lee"].eval("return ns.Guild:GetGuildPhase()") == 1
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# phase (Addendum E §32)
# ------------------------------------------------------------------------------------------------------------------
@case
def raid_leaders_phase_is_a_group_rule_on_top_of_the_guild_phase():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Out", 3, "MAGE")])
    gm_pick(w, c["Gina"], [], phase=2)                  # the guild phase
    for n in c:
        assert c[n].eval("return ns.Guild:GetGuildPhase()") == 2, n
    w.make_raid([c["Lee"], c["Rita"], c["Gina"]], leader=c["Lee"])
    w.tick(8)
    assert c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 2, "no group phase set: the guild phase"
    # the leader sets the raid's phase in Settings ("Raid phase")
    open_settings(c["Lee"])
    dd = c["Lee"].eval("return ns.SettingsUI.phaseRuleDD")
    assert c["Lee"].eval("local d = ...; return d:IsEnabled()", dd) is True
    menu = c["Lee"].dropdown_menu(dd)
    texts = [ch["text"] for ch in menu["children"]]
    assert texts[0] == "Use guild phase (P2)", texts
    c["Lee"].menu_select(texts[4])                      # P4
    w.tick(6)
    assert own(c["Lee"], "groupPhase") == 4
    for n in ("Lee", "Rita", "Gina"):
        assert c[n].eval("return ns.Guild:GetGuildPhase()") == 4, n
        assert eff(c[n], "phase") == 4, n
    assert c["Out"].eval("return ns.Guild:GetGuildPhase()") == 2, "outside the raid the guild phase applies"
    assert c["Rita"].eval("return ns.Guild:GetCouncilPhase()") == 2
    # the raider's view: read-only "Raid phase", My BiS follows and marks it as the group's phase
    open_settings(c["Rita"])
    assert c["Rita"].eval("return ns.SettingsUI.phaseRuleDD:IsEnabled()") is False
    c["Rita"].eval("ns.SettingsUI.phaseRuleDD:GenerateMenu()")
    assert c["Rita"].eval("return ns.SettingsUI.phaseRuleDD:GetText()").startswith("P4 · ")
    c["Rita"].slash("/cdl")
    w.tick(0.3)
    if c["Rita"].eval("return ns.MainFrame:GetSelectedTab()") != "mybis":
        c["Rita"].eval("ns.MainFrame:Open('mybis')")
        w.tick(0.3)
    assert c["Rita"].eval("return ns.MyBiS:GetPhase()") == 4
    c["Rita"].hover(c["Rita"].eval("return T_button(T_mybis(), 'P4')"))
    tt = [strip_codes(l[0]) for l in c["Rita"].eval_py("return T_ttlines()")]
    assert "Your group's current phase (set by Lee)" in tt, tt
    # a personal view phase still wins for the viewer only
    set_(c["Rita"], "viewPhase", 3)
    assert c["Rita"].eval("return ns.Guild:GetViewPhase()") == 3 and c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 4
    set_(c["Rita"], "viewPhase", None)
    # back to "Use guild phase"
    c["Lee"].dropdown_menu(dd)
    c["Lee"].menu_select(texts[0])
    w.tick(6)
    assert own(c["Lee"], "groupPhase") is None
    assert c["Rita"].eval("return ns.Guild:GetGuildPhase()") == 2
    # a raider cannot set the raid's phase (the GS of a non-authority is ignored)
    send_as(c["Rita"], {"t": "GS", "v": 3, "rd": 30, "q": 4, "dq": 3, "ph": 5}, "RAID")
    w.tick(1)
    assert c["Gina"].eval("return ns.Guild:GetGuildPhase()") == 2
    no_errors(w)


@case
def slash_rules_prints_the_source_and_values():
    w, c = world([("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST")])
    n0 = len(c["Rita"].chat_frame)
    c["Rita"].slash("/cdl rules")
    lines = [strip_codes(l) for l in printed_since(c["Rita"], n0)]
    assert lines[0] == "CDLoot: loot rules: your own settings (not in a group).", lines
    assert lines[1].startswith("CDLoot:   rolls 30s, drops epics+, dungeon mode off"), lines
    set_(c["Lee"], "roll.duration", 15)
    set_(c["Lee"], "groupPhase", 2)
    w.make_raid([c["Lee"], c["Rita"]], leader=c["Lee"])
    w.tick(8)
    n0 = len(c["Rita"].chat_frame)
    c["Rita"].slash("/cdl rules")
    lines = [strip_codes(l) for l in printed_since(c["Rita"], n0)]
    assert lines[0] == "CDLoot: loot rules: set by Lee for this group.", lines
    assert "rolls 15s" in lines[1] and "phase 2" in lines[1], lines
    n0 = len(c["Lee"].chat_frame)
    c["Lee"].slash("/cdl rules")
    assert strip_codes(printed_since(c["Lee"], n0)[0]) == "CDLoot: loot rules: you set these for your group."
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# party
# ------------------------------------------------------------------------------------------------------------------
@case
def party_leader_enables_dungeon_mode_for_everyone_a_plain_member_cannot():
    w, c = world([("Gina", 0, "PALADIN"), ("Carl", 3, "WARRIOR"), ("Dora", 3, "PRIEST"), ("Erin", 3, "ROGUE")])
    w.make_party([c["Carl"], c["Dora"], c["Erin"]], leader=c["Carl"])
    w.tick(8)
    for n in ("Carl", "Dora", "Erin"):
        assert authority(c[n]) is None, "a plain party leader without dungeon mode is no authority"
    # a plain member turns it on: only for herself (no authority), nobody else, no GS / DM
    mark = len(w.addon_log)
    c["Dora"].slash("/cdl dungeon on")
    w.tick(2)
    assert gs_from(w, "Dora", mark) == [] and lr.msgs_of_type(w, "DM", mark) == []
    assert c["Dora"].eval("return ns.Util.IsDungeonModeActive()") is True
    for n in ("Carl", "Erin"):
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is False, n
    c["Dora"].slash("/cdl dungeon off")
    # the party leader turns it on: the leader becomes the authority, every member is active
    set_(c["Carl"], "dungeon.quality", 4)
    c["Carl"].slash("/cdl dungeon on")
    w.tick(3)
    gs = gs_from(w, "Carl", mark)
    assert gs and gs[-1]["dm"] is True and gs[-1]["dq"] == 4 and gs[-1]["_chat_type"] == "PARTY", gs
    for n in ("Carl", "Dora", "Erin"):
        assert authority(c[n]) == K("Carl"), n
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is True, n
        assert eff(c[n], "dungeon.quality") == 4, n
    # Dora's own switch is read-only now, and turning hers on/off changes nothing for the party
    c["Dora"].slash("/cdl dungeon off")
    w.tick(2)
    assert c["Erin"].eval("return ns.Util.IsDungeonModeActive()") is True
    assert c["Dora"].eval("return ns.Util.IsDungeonModeActive()") is True, "the authority's rule applies to her too"
    # the leader turns it off: the party drops the leader's rules (one final GS) and goes back to own values
    c["Carl"].slash("/cdl dungeon off")
    w.tick(3)
    for n in ("Carl", "Dora", "Erin"):
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is False, n
        assert authority(c[n]) is None, (n, authority(c[n]))
    no_errors(w)


@case
def party_authority_order_leader_if_council_else_listed_council_by_rank():
    w, c = world([("Gina", 0, "PALADIN"), ("Olaf", 1, "MAGE"), ("Anna", 2, "PRIEST"), ("Carl", 3, "WARRIOR"),
                  ("Erin", 3, "ROGUE")], council=["Olaf", "Anna"])
    # 1) the leader is on the guild list: the leader decides
    w.make_party([c["Anna"], c["Olaf"], c["Carl"], c["Erin"]], leader=c["Anna"])
    w.tick(10)
    for n in ("Anna", "Olaf", "Carl", "Erin"):
        assert authority(c[n]) == K("Anna"), (n, authority(c[n]))
    # 2) a plain leader: the listed council member with the lowest rank index (Olaf, rank 1) decides
    w.make_party([c["Carl"], c["Anna"], c["Olaf"], c["Erin"]], leader=c["Carl"])
    for x in (c["Carl"], c["Anna"], c["Olaf"], c["Erin"]):
        x.fire("PARTY_LEADER_CHANGED")
    w.tick(12)
    for n in ("Anna", "Olaf", "Carl", "Erin"):
        assert authority(c[n]) == K("Olaf"), (n, authority(c[n]))
    set_(c["Olaf"], "roll.duration", 20)
    w.tick(6)
    assert eff(c["Erin"], "roll.duration") == 20
    # 3) ... until the plain leader turns dungeon mode on: then the leader decides
    c["Carl"].slash("/cdl dungeon on")
    w.tick(10)
    for n in ("Anna", "Olaf", "Erin"):
        assert authority(c[n]) == K("Carl"), (n, authority(c[n]))
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is True, n
    assert eff(c["Erin"], "roll.duration") == 30, "Carl's values apply now"
    # 4) the GM leads: the GM decides (always council)
    w.make_party([c["Gina"], c["Carl"], c["Erin"]], leader=c["Gina"])
    for x in (c["Gina"], c["Carl"], c["Erin"]):
        x.fire("PARTY_LEADER_CHANGED")
    w.tick(12)
    for n in ("Gina", "Carl", "Erin"):
        assert authority(c[n]) == K("Gina"), (n, authority(c[n]))
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# mixed with CDLoot 0.2
# ------------------------------------------------------------------------------------------------------------------
def mixed_world(specs):
    """specs: [(name, rank, old)] old = CDLoot 0.2.0 client (tests/grouprules/addon02)."""
    assert os.path.exists(os.path.join(ADDON_02, "CDLoot.toc")), "missing the CDLoot 0.2 fixture: %s" % ADDON_02
    w = World()
    cs = {}
    for n, r, old in specs:
        kw = {"addon_dir": ADDON_02} if old else {}
        cs[n] = Client(w, n, guild_rank=r, **kw)
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    assert cs[[n for n, _, old in specs if old][0]].eval("return ns.version") == "0.2.0"
    return w, cs


@case
def mixed_with_cdloot_02_clients_no_errors_and_dm_compatibility():
    # a 0.2 party leader turns dungeon mode on (DM): the 0.3 members follow (legacy switch)
    w, c = mixed_world([("Old", 3, True), ("New1", 3, False), ("New2", 3, False)])
    w.make_party([c["Old"], c["New1"], c["New2"]], leader=c["Old"])
    w.tick(8)
    c["Old"].slash("/cdl dungeon on")
    w.tick(2)
    for n in ("New1", "New2"):
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is True, n
        assert c[n].eval("return ns.Dungeon.groupEnabledBy") == K("Old"), n
    c["Old"].slash("/cdl dungeon off")
    w.tick(2)
    for n in ("New1", "New2"):
        assert c[n].eval("return ns.Util.IsDungeonModeActive()") is False, n
    no_errors(w)
    # a 0.3 party leader (the authority) turns it on: its DM reaches the 0.2 member
    w, c = mixed_world([("New", 3, False), ("Old", 3, True)])
    w.make_party([c["New"], c["Old"]], leader=c["New"])
    w.tick(8)
    mark = len(w.addon_log)
    c["New"].slash("/cdl dungeon on")
    w.tick(2)
    assert [m for m in lr.msgs_of_type(w, "DM", mark) if m["_sender"] == K("New") and m["on"] is True]
    assert c["Old"].eval("return ns.Util.IsDungeonModeActive()") is True
    c["New"].slash("/cdl dungeon off")
    w.tick(2)
    assert c["Old"].eval("return ns.Util.IsDungeonModeActive()") is False
    no_errors(w)
    # a 0.2 raid leader (no GS) with a 0.3 master looter: the ML is the authority for the 0.3 raiders
    w, c = mixed_world([("Old", 3, True), ("Ml", 3, False), ("New", 3, False)])
    set_(c["Ml"], "roll.duration", 45)
    w.make_raid([c["Old"], c["Ml"], c["New"]], leader=c["Old"], master_looter=c["Ml"])
    w.tick(15)
    assert authority(c["New"]) == K("Ml"), authority(c["New"])
    assert eff(c["New"], "roll.duration") == 45
    assert c["New"].eval("return ns.Guild:IsCouncil(...)", K("Old")) is True, "the raid leader is council (E §29)"
    # the 0.2 client ignores GS / GQ / CG / CR without errors
    c["Ml"].eval("ns.DB:SetSetting('roll.duration', 60)")
    w.tick(6)
    assert eff(c["New"], "roll.duration") == 60
    no_errors(w)


if __name__ == "__main__":
    run_all()
