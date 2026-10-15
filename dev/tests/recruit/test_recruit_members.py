"""Recruitment, step 4 (Core/RecruitIntro.lua, UI/NotifySources.lua): the members' side and the notifications.

Covers: a member introduces a friend while no officer is online and it reaches the first officer who comes online
(unclaimed, with who introduced them and the line; taken once); the GM turning introductions off; the member hears
when the friend joins; "How did it go?" asked of a member, answered, landing in the person's story for every officer;
an answer nobody asked for is dropped; "Take them along?" Sure / Not tonight; the officers' notifications (an
introduction, a follow-up when they're online, a check-in, a quiet new member) and the raid leaders' "joined".
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_members.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45
REALM = "Thunderstrike"
DAY = 86400


def K(name):
    return name + "-" + REALM


def guild():
    """Gina GM, Bob officer, Cora and Dan members; Kaelthorn and Thalric outside the guild."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Cora", 3, "PRIEST"), ("Dan", 3, "ROGUE")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for name, cls in (("Kaelthorn", "PALADIN"), ("Thalric", "WARRIOR")):
        c[name] = Client(w, name, guild=None, class_file=cls, level=60)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    return w, c


def person(cl, name):
    return cl.eval_py("return ns.Recruit:Get(...)", K(name))


def items(cl, kind):
    res = cl.eval_py("local out = {} for _, it in ipairs(ns.Notify:List()) do if it.kind == ... then "
                     "out[#out + 1] = it.key end end table.sort(out) return out", kind)
    return list(res.values()) if isinstance(res, dict) else (res or [])


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def intro(cl, name, line):
    return cl.eval_py("local ok, e = ns.RecruitIntro:Introduce(...); return { ok = ok, e = e }", name, line)


@case
def an_introduction_waits_for_an_officer_and_is_taken_once():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    gina.logout()
    bob.logout()
    w.tick(2)
    assert intro(cora, "Thalric", "My cousin, coming back after 15 years.")["ok"] is True
    w.tick(5)
    i = lst(cora.eval_py("return ns.RecruitIntro:GetIntros()"))
    assert len(i) == 1 and i[0]["key"] == K("Thalric") and not i[0].get("ack"), i
    bob.login()
    w.tick(SETTLE)
    p = person(bob, "Thalric")
    assert p and p.get("w") is None and p["ib"] == K("Cora") and p["it"] == "My cousin, coming back after 15 years.", p
    assert lst(cora.eval_py("return ns.RecruitIntro:GetIntros()"))[0].get("ack"), "taken"
    assert items(bob, "recruit") == ["u:" + K("Thalric")], items(bob, "recruit")
    # Gina comes online later: she gets it through the officers' sync, not a second introduction
    gina.login()
    w.tick(SETTLE)
    assert person(gina, "Thalric")["ib"] == K("Cora")
    # a member never sees the record
    assert person(cora, "Thalric") is None
    w.assert_no_errors()


@case
def the_gm_can_turn_introductions_off():
    w, c = guild()
    gina, cora = c["Gina"], c["Cora"]
    gina.eval("ns.Guild:SetRecruitRules({ it = false })")
    w.tick(5)
    assert cora.eval("return ns.RecruitIntro:CanIntroduce()") is False
    assert intro(cora, "Thalric", "x")["ok"] is False
    w.assert_no_errors()


@case
def the_member_hears_when_their_friend_joins():
    w, c = guild()
    gina, cora = c["Gina"], c["Cora"]
    intro(cora, "Thalric", "My cousin.")
    w.tick(5)
    gina.eval("ns.Recruit:Claim(...)", K("Thalric"))
    w.tick(3)
    assert gina.eval_py("return { ns.Recruit:Invite(...) }", K("Thalric"))[0] is True
    w.tick(1)
    c["Thalric"].eval("AcceptGuild()")
    w.tick(5)
    assert items(cora, "recruitAsk") == ["j:" + K("Thalric")], items(cora, "recruitAsk")
    w.assert_no_errors()


@case
def how_did_it_go_lands_in_the_story():
    w, c = guild()
    gina, bob, cora, dan = c["Gina"], c["Bob"], c["Cora"], c["Dan"]
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1 })")
    w.tick(5)
    assert gina.eval_py("return { ns.RecruitIntro:AskHowItWent(...) }", K("Kaelthorn"), K("Cora"))[0] is True
    w.tick(3)
    asks = lst(cora.eval_py("return ns.RecruitIntro:GetAsks()"))
    assert len(asks) == 1 and asks[0]["kind"] == "q" and asks[0]["by"] == K("Gina"), asks
    assert items(cora, "recruitAsk") == ["q:%s:%d" % (K("Kaelthorn"), asks[0]["at"])], items(cora, "recruitAsk")
    # Dan sends an answer nobody asked him for: dropped
    dan.eval("ns.Comm:Send({ t = 'RCW', k = 'Kaelthorn-Thunderstrike', t2 = 'terrible!' }, 'WHISPER', 'Gina-Thunderstrike', 'data')")
    w.tick(3)
    assert cora.eval_py("return { ns.RecruitIntro:Answer(...) }", asks[0]["id"], "Super nice, listened to every pull.")[0] is True
    w.tick(5)
    for x in (gina, bob):
        n = lst(person(x, "Kaelthorn").get("n"))
        assert [e["t"] for e in n] == ['"Super nice, listened to every pull."'] and n[0]["by"] == K("Cora"), (x.name, n)
    assert items(cora, "recruitAsk") == []
    w.assert_no_errors()


@case
def take_them_along_sure_or_not_tonight():
    w, c = guild()
    gina, cora, dan = c["Gina"], c["Cora"], c["Dan"]
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1 })")
    w.tick(5)
    gina.eval("local k, m = ...; ns.RecruitIntro:AskTakeAlong(k, m, 'tonight in Ramparts?')", K("Kaelthorn"), K("Cora"))
    gina.eval("ns.RecruitIntro:AskTakeAlong(...)", K("Kaelthorn"), K("Dan"))
    w.tick(3)
    a = lst(cora.eval_py("return ns.RecruitIntro:GetAsks()"))[0]
    assert a["kind"] == "t" and a["lv"] == 60, a
    cora.eval("ns.RecruitIntro:TakeAlong(..., true)", a["id"])
    d = lst(dan.eval_py("return ns.RecruitIntro:GetAsks()"))[0]
    dan.eval("ns.RecruitIntro:TakeAlong(..., false)", d["id"])
    w.tick(5)
    n = [e["t"] for e in lst(person(gina, "Kaelthorn").get("n"))]
    assert n == ["Cora will take them along."], n
    assert any("not tonight" in l for l in gina.chat_frame), gina.chat_frame[-5:]
    w.assert_no_errors()


@case
def the_officers_notifications():
    w, c = guild()
    gina, bob, kael = c["Gina"], c["Bob"], c["Kaelthorn"]
    # a follow-up that's due: only for who talks with them, and only while they're online (the friends list)
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1 })")
    w.tick(6)
    gina.eval("ns.Recruit:Update('Kaelthorn-Thunderstrike', { follow = { at = GetServerTime() - 60, t = 'a dungeon' } })")
    w.tick(3)
    f = items(gina, "recruit")
    assert len(f) == 1 and f[0].startswith("f:" + K("Kaelthorn")), f
    assert items(bob, "recruit") == []
    kael.logout()
    w.tick(3)
    assert items(gina, "recruit") == [], items(gina, "recruit")
    kael.login()
    w.tick(5)
    assert len(items(gina, "recruit")) == 1
    # a check-in due (joined a week ago, invited by Gina), a quiet one (offline 20 days)
    gina.eval("""local now = GetServerTime()
        ns.Recruit:Add('Bramble-Thunderstrike', { c = 'DRUID' })
        ns.Recruit:Note('Bramble-Thunderstrike', { st = 'joined', ja = now - 8 * 86400, jb = 'Gina-Thunderstrike', la = now })
        ns.Recruit:Add('Fennick-Thunderstrike', { c = 'ROGUE' })
        ns.Recruit:Note('Fennick-Thunderstrike', { st = 'joined', ja = now - 40 * 86400, jb = 'Gina-Thunderstrike',
            la = now - 20 * 86400, ck = { w = true, m = true } })""")
    w.tick(5)
    keys = items(gina, "recruit")
    assert "c:%s:w" % K("Bramble") in keys and "q:" + K("Fennick") in keys, keys
    # Home folds them into one chip
    chips = gina.eval_py("local out = {} for _, it in ipairs(ns.Notify:List({ home = true })) do if it.kind == 'recruit' "
                         "then out[#out + 1] = it.key end end return out")
    assert len(lst(chips)) == 3, chips
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
