"""Recruitment, step 3 (Core/Recruit.lua): the friends list and the guild invite, on the mock's friends list and
GuildInvite (the enUS system messages).

Covers: the people I talk with go on my friends list (only those; passing someone on moves them to the new
officer's list; the switch off keeps them off), their online state / level / zone; the invite: joining marks them
Joined (by me, level then, the team that fits), posts the welcome line in guild chat, writes the officer note
(the game's 31 bytes), puts them on the team's bench and tells the raid leaders, takes them off my friends list;
declined, no answer, still in another guild and offline (kept, and a reminder when they come online) each recorded.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_invite.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45
REALM = "Thunderstrike"
THU, SUN = 3 * 1440 + 19 * 60 + 30, 6 * 1440 + 19 * 60 + 30


def K(name):
    return name + "-" + REALM


def guild(pugs=(("Kaelthorn", "PALADIN"), ("Aurelith", "PALADIN"))):
    """Gina GM, Bob officer, Lee raid leader (rank 2, listed), Cora member; pugs outside any guild."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 2, "WARRIOR"), ("Cora", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for name, cls in pugs:
        c[name] = Client(w, name, guild=None, class_file=cls, level=68)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    c["Gina"].eval("ns.Guild:SetRaidLeaders({ 'Lee-Thunderstrike' })")
    w.tick(3)
    return w, c


def person(cl, name):
    return cl.eval_py("return ns.Recruit:Get(...)", K(name))


def friends(cl):
    return sorted(f["name"].split("-")[0] for f in cl.friends)


def add(w, cl, name, **opts):
    res = cl.eval_py("local ok, r = ns.Recruit:Add(...); return { ok = ok, r = r }", K(name), opts)
    assert res["ok"] is True, res
    w.tick(5)


def invite(cl, name, opts=None):
    return cl.eval_py("local ok, r = ns.Recruit:Invite(...); return { ok = ok, r = r }", K(name), opts)


@case
def the_people_i_talk_with_go_on_my_friends_list():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    add(w, gina, "Kaelthorn", c="PALADIN", sp=1)
    add(w, gina, "Aurelith", c="PALADIN", claim=False)          # unclaimed: nobody's list
    assert friends(gina) == ["Kaelthorn"], gina.friends
    assert friends(bob) == []
    live = gina.eval_py("return ns.Recruit:Live(...)", K("Kaelthorn"))
    assert live["online"] is True and live["lv"] == 68 and live["zone"], live
    # what I learn goes on their card: the level
    w.tick(2)
    assert person(bob, "Kaelthorn")["lv"] == 68
    # offline, then back
    c["Kaelthorn"].logout()
    w.tick(2)
    assert gina.eval_py("return ns.Recruit:Live(...)", K("Kaelthorn"))["online"] is False
    c["Kaelthorn"].login()
    w.tick(3)
    assert gina.eval_py("return ns.Recruit:Live(...)", K("Kaelthorn"))["online"] is True
    # passed to Bob: off Gina's list, on Bob's
    gina.eval("ns.Recruit:PassTo(...)", K("Kaelthorn"), K("Bob"))
    w.tick(8)
    assert friends(gina) == [] and friends(bob) == ["Kaelthorn"], (gina.friends, bob.friends)
    # a friend Gina added herself stays when the addon is done with them
    gina.eval("C_FriendList.AddFriend('Aurelith', 'my own')")
    gina.eval("ns.Recruit:Claim(...)", K("Aurelith"))
    w.tick(5)
    gina.eval("ns.Recruit:NotNow(...)", K("Aurelith"))
    w.tick(5)
    assert friends(gina) == ["Aurelith"], gina.friends
    # the switch off: nobody is added
    bob.eval("ns.Recruit:SetFriendsOn(false)")
    w.tick(5)
    assert friends(bob) == [], bob.friends
    w.assert_no_errors()


@case
def joining_does_the_chores():
    w, c = guild()
    gina, bob, lee, kael = c["Gina"], c["Bob"], c["Lee"], c["Kaelthorn"]
    tid = gina.eval_py("""
        local ok, id = ns.RaidPlan:SaveTeam(nil, 'Main team', {}, { size = 10, comp = { PALADIN = { 1 } },
            nights = { { w = %d, m = 210 }, { w = %d, m = 210, o = true } } })
        return id""" % (THU, SUN))
    w.tick(3)
    add(w, gina, "Kaelthorn", c="PALADIN", sp=1)
    gina.eval("ns.Recruit:Update(..., { nights = { 4, 7 }, wants = { raid = true } })", K("Kaelthorn"))
    w.tick(5)
    d = gina.eval_py("return ns.Recruit:InviteDefaults(...)", K("Kaelthorn"))
    assert d["team"] == tid and d["teamName"] == "Main team", d
    assert "Kaelthorn" in d["welcome"] and d["note"].startswith("Joined "), d
    d["welcome"] = "Everyone say hi to Kaelthorn, our new holy paladin!"
    assert invite(gina, "Kaelthorn", d)["ok"] is True
    w.tick(2)
    assert any(e["result"] == "invited" for e in w.guild_invite_log), w.guild_invite_log
    kael.eval("AcceptGuild()")
    w.tick(10)
    p = person(bob, "Kaelthorn")
    assert p["st"] == "joined" and p["jb"] == K("Gina") and p["jl"] == 68 and p["tm"] == tid, p
    said = [e["text"] for e in w.chat_log if e["chat_type"] == "GUILD" and e["sender"] == K("Gina")]
    assert said == ["Everyone say hi to Kaelthorn, our new holy paladin!"], said
    note = w.notes.get(K("Kaelthorn"), {}).get("officer", "")
    assert note.startswith("Joined ") and len(note.encode("utf-8")) <= 31, note
    members = gina.eval_py("return ns.RaidPlan:GetTeam(...).members", tid)
    assert K("Kaelthorn") in list(members.values() if isinstance(members, dict) else members), members
    news = lee.eval_py("return ns.Recruit:GetTeamNews()")
    news = list(news.values()) if isinstance(news, dict) else (news or [])
    assert news and news[0]["key"] == K("Kaelthorn") and news[0]["team"] == tid, news
    team_text = ("for _, it in ipairs(ns.Notify:List()) do if it.kind == 'recruitTeam' then "
                 "return it.text end end")
    assert lee.eval(team_text).endswith("on Main team's bench"), lee.eval(team_text)
    # off the team again: the word for the raid leaders no longer says they are on its bench
    gina.eval("ns.RaidPlan:SaveTeam(..., 'Main team', {}, {})", tid)
    w.tick(5)
    assert lee.eval(team_text).endswith("for Main team"), lee.eval(team_text)
    assert friends(gina) == [], gina.friends
    w.assert_no_errors()


@case
def a_long_officer_note_is_never_cut_inside_a_letter():
    w, c = guild()
    gina, kael = c["Gina"], c["Kaelthorn"]
    add(w, gina, "Kaelthorn", c="PALADIN", sp=1)
    d = gina.eval_py("return ns.Recruit:InviteDefaults(...)", K("Kaelthorn"))
    d["note"] = "x" * 30 + "ä" + "yz"   # the game's 31 bytes end inside the "ä"
    # (the raw bytes the addon hands the game: the mock's note store would hide a broken letter)
    gina.eval("local set = GuildRosterSetOfficerNote; GuildRosterSetOfficerNote = function(i, s) "
              "_G.DZ_TEST_NOTE = { #s, s:byte(-1) }; return set(i, s) end")
    assert invite(gina, "Kaelthorn", d)["ok"] is True
    w.tick(2)
    kael.eval("AcceptGuild()")
    w.tick(10)
    got = gina.eval_py("return _G.DZ_TEST_NOTE")
    got = list(got.values()) if isinstance(got, dict) else got
    assert got == [30, ord("x")], got
    w.assert_no_errors()


@case
def declined_no_answer_and_in_another_guild_are_recorded():
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    c["Kael"] = Client(w, "Kael", guild=None, class_file="PALADIN")
    c["Aure"] = Client(w, "Aure", guild=None, class_file="PRIEST")
    c["Other"] = Client(w, "Other", guild="Old Friends", guild_rank=3, class_file="ROGUE")
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    gina, bob = c["Gina"], c["Bob"]
    for n in ("Kael", "Aure", "Other"):
        add(w, gina, n)
    assert invite(gina, "Kael")["ok"] is True
    w.tick(1)
    c["Kael"].eval("DeclineGuild()")
    w.tick(5)
    p = person(bob, "Kael")
    assert p["st"] == "talk" and p["iv"]["r"] == "declined", p
    assert invite(gina, "Other")["ok"] is True
    w.tick(5)
    assert person(bob, "Other")["iv"]["r"] == "guild"
    assert invite(gina, "Aure")["ok"] is True
    w.tick(125)
    assert person(bob, "Aure")["iv"]["r"] == "ignored"
    w.assert_no_errors()


@case
def an_offline_invite_waits_and_reminds_when_they_come_online():
    w, c = guild()
    gina, kael = c["Gina"], c["Kaelthorn"]
    add(w, gina, "Kaelthorn", c="PALADIN", sp=1)
    kael.logout()
    w.tick(3)
    res = invite(gina, "Kaelthorn")
    assert res == {"ok": True, "r": "queued"}, res
    assert gina.eval("return ns.Recruit:InviteQueued(...)", K("Kaelthorn")) is True
    assert not any(e["target"].startswith("Kaelthorn") for e in getattr(w, "guild_invite_log", []))
    gina.eval("__ready = nil; ns:On('RECRUIT_INVITE_READY', function(k) __ready = k end)")
    kael.login()
    w.tick(5)
    assert gina.eval("return __ready") == K("Kaelthorn")
    # (the toast's click sends it)
    assert invite(gina, "Kaelthorn", gina.eval_py("return ns.Recruit:QueuedOpts(...)", K("Kaelthorn")))["ok"] is True
    w.tick(1)
    assert gina.eval("return ns.Recruit:InviteQueued(...)", K("Kaelthorn")) is False
    kael.eval("AcceptGuild()")
    w.tick(10)
    assert person(gina, "Kaelthorn")["st"] == "joined"
    w.assert_no_errors()


@case
def a_member_cant_invite_through_recruitment():
    w, c = guild()
    gina, cora = c["Gina"], c["Cora"]
    add(w, gina, "Kaelthorn")
    assert invite(cora, "Kaelthorn")["ok"] is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
