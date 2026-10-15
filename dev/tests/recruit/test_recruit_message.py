"""Recruitment, step 6 (Core/RecruitMessage.lua): the recruitment message, built by the officers from parts, and its
places.

Covers: the message starts empty and says only what the parts say (their words; the helpers' facts: the guild's name,
a team's open comp places as specs or classes, any left out, every team's, a team's nights), in their order (moved,
left out, removed), joined as picked; one line, 255 at most (a longer one isn't posted); the 1.6 beta's text and
minutes carry over; places: Trade and GuildRecruitment at first, Say / Yell / any channel added, each with its own
interval (30 seconds to 12 hours) and a "major cities only" tick; Post goes to every place that is on, skips the ones
I can't post to now and says why; officers take turns per place; the reminder: only the places that are due; the key
binding posts what is due; a member can't post; Raids > Guests' Recruit mark brings a guest into Recruitment.
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


def say(cl, text):
    cl.eval("ns.RecruitMessage:AddPart('text', { t = ... })", text)


def compose(cl):
    return cl.eval_py("return { ns.RecruitMessage:Compose() }")


TEAM = """__team = { id = 't1', name = 'SSC team', nights = { { w = 3 * 1440 + 19 * 60 + 30, m = 210 },
    { w = 6 * 1440 + 19 * 60 + 30, m = 210, o = true } } }
__team2 = { id = 't2', name = 'Owls', nights = { { w = 21 * 60, m = 180 } } }
ns.RaidPlan.GetTeams = function() return { __team, __team2 } end
ns.RaidPlan.GetTeamOpenSlots = function(_, t)
  if t.id == 't1' then return { { c = 'PALADIN', sp = 1, role = 'healer' }, { c = 'DRUID', sp = 4, role = 'healer' },
    { c = 'PALADIN', sp = 3, role = 'melee' } }, 3 end
  return { { c = 'PALADIN', sp = 1, role = 'healer' }, { c = 'WARRIOR', sp = 3, role = 'tank' } }, 2 end"""


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


@case
def the_message_is_ours():
    w, c = guild()
    gina = c["Gina"]
    assert compose(gina)[0] is None                                          # nothing written for us
    assert gina.eval("return #ns.RecruitMessage:GetParts()") == 0
    say(gina, "chill guild,\nwe raid")
    gina.eval("ns.RecruitMessage:AddPart('tag')")
    tag = "<" + gina.eval("return (GetGuildInfo('player'))") + ">"
    res = compose(gina)
    assert res[0] == "chill guild, we raid " + tag and res[2] is False, res
    # moved, joined with " - ", left out, removed
    ids = lst(gina.eval_py("local o = {} for _, p in ipairs(ns.RecruitMessage:GetParts()) do o[#o + 1] = p.id end return o"))
    gina.eval("ns.RecruitMessage:MovePart(..., 1)", ids[1])
    gina.eval("ns.RecruitMessage:SetSep(' - ')")
    assert compose(gina)[0] == tag + " - chill guild, we raid", compose(gina)
    gina.eval("ns.RecruitMessage:SetPart(..., { on = false })", ids[0])
    assert compose(gina)[0] == tag, compose(gina)
    gina.eval("ns.RecruitMessage:RemovePart(...)", ids[0])
    assert gina.eval("return #ns.RecruitMessage:GetParts()") == 1
    say(gina, "x" * 200)
    say(gina, "y" * 100)
    res = compose(gina)
    assert res[2] is True and res[1] > 255, res
    assert post(gina)["ok"] is False
    w.assert_no_errors()


@case
def the_helpers_fill_in_the_teams():
    w, c = guild()
    gina = c["Gina"]
    gina.eval(TEAM)
    gina.eval("ns.RecruitMessage:AddPart('need', { team = 't1' })")
    nid = gina.eval("return ns.RecruitMessage:GetParts()[1].id")
    assert compose(gina)[0] == "Holy Paladin, Restoration Druid, Retribution Paladin", compose(gina)
    gina.eval("ns.RecruitMessage:SetPart(..., { skip = 'PALADIN:3' })", nid)
    assert compose(gina)[0] == "Holy Paladin, Restoration Druid", compose(gina)
    gina.eval("ns.RecruitMessage:SetPart(..., { by = 'short' })", nid)      # (what's left out stays out)
    assert compose(gina)[0] == "Holy Pala, Resto Druid", compose(gina)
    gina.eval("ns.RecruitMessage:SetPart(..., { by = 'class' })", nid)      # (a new list: nothing left out)
    assert compose(gina)[0] == "Paladin, Druid", compose(gina)
    gina.eval("ns.RecruitMessage:SetPart(..., { team = 'all', by = 'spec' })", nid)
    assert compose(gina)[0] == "Holy Paladin, Restoration Druid, Retribution Paladin, Protection Warrior", compose(gina)
    gina.eval("ns.RecruitMessage:RemovePart(...)", nid)
    gina.eval("ns.RecruitMessage:AddPart('nights', { team = 't1' })")
    assert compose(gina)[0] == "Thu + Sun 19:30", compose(gina)
    gina.eval("ns.RecruitMessage:AddPart('nights', { team = 't2' })")
    assert compose(gina)[0] == "Thu + Sun 19:30 Mon 21:00", compose(gina)
    # nights can't be "every team" (the first team then); a team without nights says nothing
    assert gina.eval_py("return { ns.RecruitMessage:AddPart('nights', { team = 'all' }) }")[0] is True
    assert gina.eval("return ns.RecruitMessage:GetParts()[3].team") == "t1"
    gina.eval("__team2.nights = {}")
    assert compose(gina)[0] == "Thu + Sun 19:30 Thu + Sun 19:30", compose(gina)
    w.assert_no_errors()


@case
def raid_icons_go_in_as_parts_or_into_the_words():
    w, c = guild()
    gina = c["Gina"]
    say(gina, "LF healers")
    first = gina.eval("return ns.RecruitMessage:GetParts()[1].id")
    # a part after the picked one, swapped
    gina.eval("ns.RecruitMessage:AddPart('icon', { m = 8 })")
    gina.eval("ns.RecruitMessage:AddPart('icon', { m = 1, after = ... })", first)
    assert compose(gina)[0] == "LF healers {rt1} {rt8}", compose(gina)
    star = gina.eval("return ns.RecruitMessage:GetParts()[2].id")
    gina.eval("ns.RecruitMessage:SetPart(..., { m = 2 })", star)
    assert compose(gina)[0] == "LF healers {rt2} {rt8}", compose(gina)
    # the page: with the words picked, a click puts the icon in at the cursor
    gina.slash("/dz recruit")
    w.tick(0.5)
    gina.eval("ns.RecruitUI:GetState().part = ...; ns.RecruitUI:SetView('message')", first)
    w.tick(0.5)
    gina.eval("local w = ns.RecruitUI:GetPanel().message.w; w.wordsCursor = 2")
    gina.eval("ns.RecruitUI._H.IconClick(8)")
    assert compose(gina)[0] == "LF {rt8} healers {rt2} {rt8}", compose(gina)
    # the preview draws them; {star} written by hand too
    shown = gina.eval("return ns.RecruitMessage:Render('{rt8} {Star} {nope}')")
    assert shown.count("UI-RaidTargetingIcon_8") == 1 and "UI-RaidTargetingIcon_1" in shown and "{nope}" in shown, shown
    assert "RaidTargetingIcon_8" in gina.eval("return ns.RecruitUI:GetPanel().message.prevText:GetText()")
    w.assert_no_errors()


@case
def the_beta_message_carries_over():
    w, c = guild()
    gina = c["Gina"]
    gina.eval("local d = ns.DB:GuildBucket('recruitMsg', true) "
              "for k in pairs(d) do d[k] = nil end "
              "d.v = 2; d.text = 'Chill guild, /w me' "
              "d.places = { { id = 'ch:trade', kind = 'CHANNEL', name = 'Trade', every = 45, on = true, city = true } }")
    assert compose(gina)[0] == "Chill guild, /w me"
    assert places(gina) == [("ch:trade", 2700, True, True)], places(gina)
    w.assert_no_errors()


@case
def places_each_with_their_own_interval():
    w, c = guild()
    gina = c["Gina"]
    assert places(gina) == [("ch:trade", 3600, True, True), ("ch:guildrecruitment", 3600, True, True)], places(gina)
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('YELL', nil, 30) }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'General', 1200) }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'disasterhangout') }")[0] is True
    assert gina.eval_py("return { ns.RecruitMessage:AddPlace('CHANNEL', 'trade') }")[0] is False     # already there
    gina.eval("ns.RecruitMessage:SetPlace('ch:trade', { every = 45, city = false })")
    gina.eval("ns.RecruitMessage:SetPlace('yell', { every = 0 }); ns.RecruitMessage:SetPlace('ch:general', { every = 99999 })")
    gina.eval("ns.RecruitMessage:RemovePlace('ch:guildrecruitment')")
    p = {x[0]: x for x in places(gina)}
    assert p["ch:trade"] == ("ch:trade", 45, True, False), p
    assert p["yell"][1] == 30 and p["yell"][3] is True, p                 # (Say / Yell: cities only at first)
    assert p["ch:general"][1] == 12 * 3600 and p["ch:general"][3] is False, p
    assert "ch:guildrecruitment" not in p and "ch:disasterhangout" in p, p
    w.assert_no_errors()


@case
def post_goes_where_it_can_and_says_where_it_couldnt():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    for x in (gina, cora):
        say(x, "Chill guild, /w me")
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
    say(gina, "Chill guild, /w me")
    gina.eval("ns.RecruitMessage:AddPlace('YELL', nil, 30); ns.RecruitMessage:SetPlace('ch:guildrecruitment', { on = false })")
    post(gina)                                                               # Trade + Yell now
    gina.eval("__due = nil; ns:On('RECRUIT_MSG_READY', function(d) __due = d end); ns.RecruitMessage:SetRepeat(true)")
    w.tick(10)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert gina.eval("return __due") is None
    res = gina.eval_py("return { ns.RecruitMessage:PostByKey() }")             # the key: nothing due yet
    assert res[0] is False and "Yell in" in res[1], res
    w.tick(21)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert lst(gina.eval_py("return __due")) == ["yell"], gina.eval_py("return __due")
    gina.eval("DisasterZone_PostRecruit()")                                  # the key posts what is due
    assert gina.eval("return ns.RecruitMessage:LastPost('yell') > ns.RecruitMessage:LastPost('ch:trade')") is True
    w.tick(3600 - 31)
    gina.eval("ns.RecruitMessage:_Tick()")
    assert lst(gina.eval_py("return ns.RecruitMessage:Ready()")) == ["ch:trade", "yell"], gina.eval_py("return ns.RecruitMessage:Ready()")
    w.assert_no_errors()


@case
def lately_counts_posts_and_who_whispered_after_one():
    w, c = guild()
    gina = c["Gina"]
    say(gina, "Chill guild, /w me")
    post(gina)
    w.tick(600)
    gina.eval("ns.Recruit:Add('Aurelith-Thunderstrike', { c = 'PALADIN', src = 'whisper' })")
    gina.eval("ns.Recruit:Add('Thalric-Thunderstrike', { c = 'WARRIOR', src = 'intro' })")
    w.tick(2)
    l = gina.eval_py("local l = ns.RecruitMessage:Lately(); return { week = l.week, came = #l.came, joined = l.joined }")
    assert l == {"week": 1, "came": 1, "joined": 0}, l
    w.assert_no_errors()


@case
def a_guest_marked_recruit_comes_into_recruitment():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    # the Recruit mark in Raids > Guests (a raid leader's way in): the officers get them, unclaimed
    gina.eval("ns.GuestBook:SetNote('Pugsy-Thunderstrike', 'nice healer', true, 'PRIEST', 1)")
    w.tick(8)
    r = bob.eval_py("return ns.Recruit:Get('Pugsy-Thunderstrike')")
    assert r and r["src"] == "guest" and r["c"] == "PRIEST" and r.get("w") is None, r
    assert bob.eval("return ns.GuestBookUI._H.IsRecruit('Pugsy-Thunderstrike')") is True
    # removed from Recruitment: the mark goes, and they stay out
    gina.eval("ns.Recruit:Remove('Pugsy-Thunderstrike')")
    w.tick(8)
    assert gina.eval("return ns.GuestBook:GetNote('Pugsy-Thunderstrike').recruit") is False
    assert bob.eval("return ns.Recruit:Get('Pugsy-Thunderstrike')") is None
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
