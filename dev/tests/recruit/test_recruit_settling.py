"""Recruitment, step 5 (Core/Recruit.lua settling in, UI/Members.lua): what the guild roster says about the people who
joined, kept up to date by whoever invited them.

Covers: levels 58 and 70 become milestones (once each); a raider at 70 is a word for the raid leaders; last online
from the roster and "gone quiet"; leaving the guild ("gone", a notification for who invited them); the member card's
"How they joined" for the GM and officers.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_settling.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45
REALM = "Thunderstrike"


def K(name):
    return name + "-" + REALM


def joined(level=50, wants_raid=True):
    """Gina GM, Bob officer, Lee listed raid leader; Kaelthorn joins through Gina's invite at `level`."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 2, "WARRIOR")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    c["Kaelthorn"] = Client(w, "Kaelthorn", guild=None, class_file="PALADIN", level=level)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    gina = c["Gina"]
    gina.eval("ns.Guild:SetRaidLeaders({ 'Lee-Thunderstrike' })")
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1 })")
    if wants_raid:
        gina.eval("ns.Recruit:Update('Kaelthorn-Thunderstrike', { wants = { raid = true }, nights = { 4 } })")
    w.tick(6)
    assert gina.eval_py("return { ns.Recruit:Invite('Kaelthorn-Thunderstrike') }")[0] is True
    w.tick(1)
    c["Kaelthorn"].eval("AcceptGuild()")
    w.tick(10)
    return w, c


def person(cl, name):
    return cl.eval_py("return ns.Recruit:Get(...)", K(name))


def roster(w, cl):
    w._sync(roster_changed=True, guild=cl.guild)
    w.tick(8)


def items(cl, kind):
    res = cl.eval_py("local out = {} for _, it in ipairs(ns.Notify:List()) do if it.kind == ... then "
                     "out[#out + 1] = it.key end end table.sort(out) return out", kind)
    return list(res.values()) if isinstance(res, dict) else (res or [])


@case
def levels_become_milestones_and_a_raider_at_70_is_a_word_for_the_raid_leaders():
    w, c = joined(level=50)
    gina, bob, lee, kael = c["Gina"], c["Bob"], c["Lee"], c["Kaelthorn"]
    p = person(bob, "Kaelthorn")
    assert p["st"] == "joined" and p["jl"] == 50, p
    kael.level = 58
    roster(w, gina)
    p = person(bob, "Kaelthorn")
    assert p["lv"] == 58 and p["ms"].get("58") or p["ms"].get(58), p
    assert gina.eval("return ns.Recruit:Section(ns.Recruit:Get('Kaelthorn-Thunderstrike'))") in ("mile", "check")
    kael.level = 70
    roster(w, gina)
    p = person(gina, "Kaelthorn")
    ms = p["ms"]
    assert (ms.get(70) or ms.get("70")), p
    news = lee.eval_py("return ns.Recruit:GetTeamNews()")
    news = list(news.values()) if isinstance(news, dict) else (news or [])
    assert any(n["key"] == K("Kaelthorn") and n["why"] == "70" for n in news), news
    assert any(k.startswith("Kaelthorn-Thunderstrike:70") for k in items(lee, "recruitTeam")), items(lee, "recruitTeam")
    # milestones once: another roster update changes nothing
    rev = p["rev"]
    roster(w, gina)
    assert person(gina, "Kaelthorn")["rev"] == rev
    w.assert_no_errors()


@case
def last_online_and_gone_quiet():
    w, c = joined(level=60, wants_raid=False)
    gina, kael = c["Gina"], c["Kaelthorn"]
    kael.logout()
    gina.eval("GetGuildRosterLastOnline = function() return 0, 0, 20, 0 end")
    roster(w, gina)
    p = person(gina, "Kaelthorn")
    assert p["la"] < gina.eval("return GetServerTime()") - 19 * 86400, p
    assert gina.eval("return ns.Recruit:QuietDays(ns.Recruit:Get('Kaelthorn-Thunderstrike'))") >= 19
    gina.eval("ns.Recruit:Note('Kaelthorn-Thunderstrike', { ja = GetServerTime() - 40 * 86400, ck = { w = true, m = true } })")
    w.tick(3)
    assert "q:" + K("Kaelthorn") in items(gina, "recruit"), items(gina, "recruit")
    w.assert_no_errors()


@case
def leaving_the_guild():
    w, c = joined(level=60, wants_raid=False)
    gina, bob, kael = c["Gina"], c["Bob"], c["Kaelthorn"]
    kael.guild = None
    roster(w, gina)
    w.tick(3)
    assert person(bob, "Kaelthorn")["st"] == "gone"
    assert any(k.startswith("l:" + K("Kaelthorn")) for k in items(gina, "recruit")), items(gina, "recruit")
    assert not any(k.startswith("l:") for k in items(bob, "recruit"))      # only who invited them
    w.assert_no_errors()


@case
def the_member_card_says_how_they_joined():
    w, c = joined(level=60, wants_raid=False)
    gina, lee = c["Gina"], c["Lee"]
    gina.slash("/dz members")
    w.tick(0.5)
    gina.eval("ns.MembersUI:ShowMember('Kaelthorn-Thunderstrike')")
    w.tick(0.5)
    assert gina.eval("local n = ns.MembersUI:GetPanel().right.note; return n:IsShown() and n.joined:IsShown()") is True
    assert gina.find_text("invited by Gina", True, True)
    lee.slash("/dz members")
    w.tick(0.5)
    lee.eval("ns.MembersUI:ShowMember('Kaelthorn-Thunderstrike')")
    w.tick(0.5)
    assert lee.eval("local n = ns.MembersUI:GetPanel().right.note; return n.joined:IsShown()") is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
