"""Recruitment, step 6 (Core/RecruitMessage.lua): the recruitment message, written by the officers, and its places.

Covers: the message is the officers' own text (one line, 255 at most: a longer one isn't posted); places: Trade and
GuildRecruitment at first, Say / Yell / any channel added, each with its own interval (1 to 720 minutes) and a
"major cities only" tick, removed again; Post goes to every place that is on, skips the ones I can't post to now
(not in a city, not in the channel) and says why; officers take turns per place (a post is told to the recruiters
online, never members); the reminder: only the places that are due, each by its own interval; a member can't post.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_message.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45
WORLD = """GetChannelName = function(name)
  if name == 'Trade' then return 2, name end
  if name == 'General' then return 1, name end
  return 0 end
GetRealZoneText = function() return __zone or 'Orgrimmar' end
C_Map.GetBestMapForUnit = function() return nil end"""


def guild():
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Cora", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    for x in c.values():
        x.eval(WORLD)
    return w, c


def places(cl):
    res = cl.eval_py("local out = {} for _, p in ipairs(ns.RecruitMessage:GetPlaces()) do "
                     "out[#out + 1] = { p.id, p.every, p.on, p.city } end return out")
    return [tuple(x.values()) if isinstance(x, dict) else tuple(x) for x in (res.values() if isinstance(res, dict) else res or [])]


def post(cl, ids=None):
    return cl.eval_py("local ok, a, b = ns.RecruitMessage:Post(...); return { ok = ok, a = a, b = b }", ids)


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


@case
def the_message_is_ours():
    w, c = guild()
    gina = c["Gina"]
    assert gina.eval_py("return { ns.RecruitMessage:Compose() }")[0] is None       # nothing written yet
    gina.eval("ns.RecruitMessage:SetText('<Casual Disaster> chill guild,\\nwe raid Thu + Sun. /w me!')")
    res = gina.eval_py("return { ns.RecruitMessage:Compose() }")
    assert res[0] == "<Casual Disaster> chill guild, we raid Thu + Sun. /w me!" and res[2] is False, res
    gina.eval("ns.RecruitMessage:SetText(string.rep('x', 300))")
    res = gina.eval_py("return { ns.RecruitMessage:Compose() }")
    assert res[1] == 300 and res[2] is True, res
    assert post(gina)["ok"] is False
    w.assert_no_errors()


@case
def places_each_with_their_own_interval():
    w, c = guild()
    gina = c["Gina"]
    assert places(gina) == [("ch:trade", 60, True, True), ("ch:guildrecruitment", 60, True, True)], places(gina)
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('YELL') }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'General', 20) }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'disasterhangout') }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'trade') }")[0] is False     # already there
    gina.eval("ns.RecruitMessage:SetPlace('ch:trade', { every = 45, city = false })")
    gina.eval("ns.RecruitMessage:SetPlace('yell', { every = 0 }); ns.RecruitMessage:SetPlace('ch:general', { every = 9999 })")
    gina.eval("ns.RecruitMessage:RemovePlace('ch:guildrecruitment')")
    p = {x[0]: x for x in places(gina)}
    assert p["ch:trade"] == ("ch:trade", 45, True, False), p
    assert p["yell"][1] == 1 and p["yell"][3] is True, p                  # (Say / Yell: cities only at first)
    assert p["ch:general"][1] == 720 and p["ch:general"][3] is False, p
    assert "ch:guildrecruitment" not in p and "ch:disasterhangout" in p, p
    w.assert_no_errors()


@case
def post_goes_where_it_can_and_says_where_it_couldnt():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    for x in (gina, cora):
        x.eval("ns.RecruitMessage:SetText('Chill guild, /w me')")
    gina.eval("ns.RecruitMessage:AddPlace('YELL'); ns.RecruitMessage:AddPlace('CHANNEL', 'General')")
    assert post(cora)["ok"] is False                                        # a member can't
    res = post(gina)
    assert res["ok"] is True and lst(res["a"]) == ["Trade", "Yell", "General"], res
    assert lst(res["b"]) == ["GuildRecruitment: you're not in GuildRecruitment"], res
    w.tick(3)
    kinds = [e["chat_type"] for e in w.chat_log if e["sender"].startswith("Gina")]
    assert kinds == ["CHANNEL", "YELL", "CHANNEL"], kinds
    # out of the city: Trade and Yell wait (cities only), General goes
    gina.eval("__zone = 'Nagrand'")
    res = post(gina)
    assert lst(res["a"]) == ["General"], res
    # Bob heard about the Trade post: Trade's turn waits for him, General's too
    assert bob.eval("return ns.RecruitMessage:LastPost('ch:trade') ~= nil") is True
    assert cora.eval("return ns.RecruitMessage:LastPost('ch:trade')") is None
    w.assert_no_errors()


@case
def the_reminder_is_per_place():
    w, c = guild()
    gina = c["Gina"]
    gina.eval("ns.RecruitMessage:SetText('Chill guild, /w me')")
    gina.eval("ns.RecruitMessage:AddPlace('YELL', nil, 5); ns.RecruitMessage:SetPlace('ch:guildrecruitment', { on = false })")
    post(gina)                                                               # Trade + Yell now
    gina.eval("__due = nil; ns:On('RECRUIT_MSG_READY', function(d) __due = d end); ns.RecruitMessage:SetRepeat(true)")
    w.tick(60)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert gina.eval("return __due") is None
    w.tick(5 * 60)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert lst(gina.eval_py("return __due")) == ["yell"], gina.eval_py("return __due")
    assert post(gina, ["yell"])["ok"] is True
    w.tick(55 * 60)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert lst(gina.eval_py("return ns.RecruitMessage:Ready()")) == ["ch:trade", "yell"], gina.eval_py("return ns.RecruitMessage:Ready()")
    w.assert_no_errors()


@case
def lately_counts_posts_and_who_whispered_after_one():
    w, c = guild()
    gina = c["Gina"]
    gina.eval("ns.RecruitMessage:SetText('Chill guild, /w me')")
    post(gina)
    w.tick(600)
    gina.eval("ns.Recruit:Add('Aurelith-Thunderstrike', { c = 'PALADIN', src = 'whisper' })")
    gina.eval("ns.Recruit:Add('Thalric-Thunderstrike', { c = 'WARRIOR', src = 'intro' })")
    w.tick(2)
    l = gina.eval_py("local l = ns.RecruitMessage:Lately(); return { week = l.week, came = #l.came, joined = l.joined }")
    assert l == {"week": 1, "came": 1, "joined": 0}, l
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
