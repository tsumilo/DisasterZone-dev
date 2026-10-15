"""Recruitment, step 6 (Core/RecruitMessage.lua): the recruitment message.

Covers: the blocks (the guild tag, who / what / my words as texts I can change, the raid nights and the classes we're
after from one team's open places, the team never named; a class left out; No team = all classes welcome); the 255
limit; Post goes to the picked channels I'm in, is told to the other officers (their next turn waits) and never to
members; the repeat: ready again after the interval since anyone's last post; Lately counts posts and the people who
whispered after one; a member can't post.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_message.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45
THU = 3 * 1440 + 19 * 60 + 30
CHANNELS = """GetChannelName = function(name)
  if name == 'Trade' then return 2, name end
  if name == 'LookingForGroup' then return 4, name end
  return 0 end"""


def guild():
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Cora", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    gina = c["Gina"]
    gina.eval_py("""
        local ok, id = ns.RaidPlan:SaveTeam(nil, 'Main team', {}, { size = 10, comp = { PALADIN = { 1 }, DRUID = { 0, 0, 0, 1 } },
            nights = { { w = %d, m = 210 } } })
        return id""" % THU)
    w.tick(3)
    return w, c


def compose(cl):
    return cl.eval_py("return { ns.RecruitMessage:Compose() }")


@case
def the_blocks_make_the_message():
    w, c = guild()
    gina = c["Gina"]
    text = compose(gina)[0]
    assert text.startswith("<Casual Disaster> (A) · chill guild"), text
    assert "raids Thursday 19:30" in text and "especially after Holy Paladin, Restoration Druid" in text, text
    assert "Main team" not in text                                  # the team is never named
    assert text.endswith("/w Gina or any officer for a chat"), text
    gina.eval("ns.RecruitMessage:SetSkipped('DRUID:4', true)")
    assert "especially after Holy Paladin ·" in compose(gina)[0]
    gina.eval("ns.RecruitMessage:SetTeam('none')")
    t = compose(gina)[0]
    assert "all classes welcome" in t and "raids " not in t, t
    gina.eval("ns.RecruitMessage:SetText('who', 'friendly bunch'); ns.RecruitMessage:SetOn('tag', false)")
    t = compose(gina)[0]
    assert t.startswith("friendly bunch · "), t
    gina.eval("ns.RecruitMessage:SetText('custom', string.rep('x', 150)); ns.RecruitMessage:SetOn('custom', true)")
    res = compose(gina)
    assert res[2] is True and res[1] > 255, res
    w.assert_no_errors()


@case
def posting_goes_to_my_channels_and_officers_take_turns():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    for x in (gina, bob):
        x.eval(CHANNELS)
    assert cora.eval_py("return { ns.RecruitMessage:Post() }")[0] is False
    res = gina.eval_py("return { ns.RecruitMessage:Post() }")
    assert res[0] is True and list(res[1].values() if isinstance(res[1], dict) else res[1]) == ["Trade", "LookingForGroup"], res
    w.tick(3)
    sent = [e for e in w.chat_log if e["chat_type"] == "CHANNEL"]
    assert len(sent) == 2 and sent[0]["text"].startswith("<Casual Disaster>"), sent
    # Bob heard the post: his next turn waits an hour after it; Cora (a member) heard nothing
    assert bob.eval("return ns.RecruitMessage:LastPost() ~= nil") is True
    assert bob.eval("return ns.RecruitMessage:NextDue() - GetServerTime() > 3500") is True
    assert cora.eval("return #ns.RecruitMessage:GetPosts()") == 0
    # the repeat: not ready before the hour, ready after
    bob.eval("ns.RecruitMessage:SetRepeat(true)")
    w.tick(10)
    assert bob.eval("return ns.RecruitMessage:IsReady()") is False
    w.tick(3600)
    assert bob.eval("return ns.RecruitMessage:IsReady()") is True
    w.assert_no_errors()


@case
def lately_counts_posts_and_who_whispered_after_one():
    w, c = guild()
    gina = c["Gina"]
    gina.eval(CHANNELS)
    gina.eval("ns.RecruitMessage:Post()")
    w.tick(600)
    gina.eval("ns.Recruit:Add('Aurelith-Thunderstrike', { c = 'PALADIN', src = 'whisper' })")
    gina.eval("ns.Recruit:Add('Thalric-Thunderstrike', { c = 'WARRIOR', src = 'intro' })")
    w.tick(2)
    l = gina.eval_py("local l = ns.RecruitMessage:Lately(); return { week = l.week, came = #l.came, joined = l.joined }")
    assert l == {"week": 1, "came": 1, "joined": 0}, l
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
