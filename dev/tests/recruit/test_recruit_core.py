"""Recruitment, step 1 (Core/Recruit.lua + the GM's rules in Core/Guild.lua): records, who works on recruits, sync,
fit with the teams, demo mode.

Covers: the GM and officers share people by whisper and nobody else ever holds them (members, outsiders); edits,
notes, claim / pass and the newer revision win; an officer who was offline catches up on login; a removal travels
as a tombstone and an old copy can't bring the person back; a hand-made record from a member is dropped; an officer
who loses the rank forgets the people; the GM's rules sync to everyone and only the GM sets them; raid leaders work
on recruits only when the rules say so; the fit with a team's raid nights and its comp's open places; demo mode shows
made-up people to anyone and sends nothing.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_core.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

SETTLE = 45          # login share (30 s) + the roster's moments
REALM = "Thunderstrike"
THU, SUN, TUE = 3 * 1440 + 19 * 60 + 30, 6 * 1440 + 19 * 60 + 30, 1 * 1440 + 20 * 60


def K(name):
    return name + "-" + REALM


def guild(extra_pug=True):
    """Gina GM, Bob officer, Lee raid rank 2, Cora member 3; Darkstalkerr outside the guild."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 2, "WARRIOR"), ("Cora", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    if extra_pug:
        c["Darkstalkerr"] = Client(w, "Darkstalkerr", guild=None, class_file="HUNTER")
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    return w, c


def add(cl, name, **opts):
    return cl.eval_py("local ok, r = ns.Recruit:Add(...); return { ok = ok, r = r }", name, opts)


def call(cl, fn, *args):
    return cl.eval_py("local fn = ...; local ok, r = ns.Recruit[fn](ns.Recruit, select(2, ...)); return { ok = ok, r = r }",
                      fn, *args)


def person(cl, name):
    return cl.eval_py("return ns.Recruit:Get(...)", K(name))


def stored(cl):
    """Every key in this client's saved recruit data (any guild bucket), whether or not it can read them."""
    return cl.eval_py("local out = {} for _, b in pairs(ns.db.recruit or {}) do for k in pairs(b.p or {}) do "
                      "out[#out + 1] = k end end table.sort(out) return out") or []


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


@case
def officers_share_people_and_nobody_else_holds_them():
    w, c = guild()
    gina, bob, lee, cora, pug = c["Gina"], c["Bob"], c["Lee"], c["Cora"], c["Darkstalkerr"]
    assert gina.eval("return ns.Recruit:CanUse()") is True
    assert bob.eval("return ns.Recruit:CanUse()") is True
    assert cora.eval("return ns.Recruit:CanUse()") is False
    res = add(gina, "Kaelthorn", c="PALADIN", sp=1, src="trade", lv=70, note="Lovely chat, wants SSC.")
    assert res["ok"] is True and res["r"] == K("Kaelthorn"), res
    w.tick(5)
    p = person(bob, "Kaelthorn")
    assert p and p["c"] == "PALADIN" and p["sp"] == 1 and p["w"] == K("Gina") and p["st"] == "talk", p
    assert lst(p["n"])[0]["t"] == "Lovely chat, wants SSC.", p
    for x in (lee, cora, pug):
        assert stored(x) == [], (x.name, stored(x))
        assert person(x, "Kaelthorn") is None
    # a member can't add, and a guild member can't be added
    assert add(cora, "Someone")["ok"] is False
    assert add(gina, "Cora")["ok"] is False
    w.assert_no_errors()


@case
def edits_notes_and_claims_sync_and_the_newer_one_wins():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    add(gina, "Aurelith", c="PALADIN", sp=1, claim=False)
    w.tick(5)
    assert person(bob, "Aurelith").get("w") is None                   # unclaimed
    assert call(bob, "Claim", K("Aurelith"))["ok"] is True
    w.tick(5)
    assert person(gina, "Aurelith")["w"] == K("Bob")
    res = call(gina, "Update", K("Aurelith"), {"wants": {"level": True, "social": True}, "nights": [7, 4, 4, 9],
                                                "time": "from 19:00", "said": "Would love to see Kara one day.",
                                                "tags": ["Chill", "New to WoW"], "follow": {"at": 2000000000, "t": "a dungeon"}})
    assert res["ok"] is True, res
    w.tick(5)
    p = person(bob, "Aurelith")
    assert lst(p["ni"]) == [4, 7] and p["nt"] == "from 19:00" and p["sd"] == "Would love to see Kara one day.", p
    assert bob.eval("local r = ns.Recruit:Get(...); return ns.Recruit:Wants(r, 'level') and ns.Recruit:Wants(r, 'social') "
                    "and not ns.Recruit:Wants(r, 'raid')", K("Aurelith")) is True
    assert lst(p["tg"]) == ["Chill", "New to WoW"] and p["fu"]["t"] == "a dungeon", p
    # notes from both, newest first
    assert call(bob, "AddNote", K("Aurelith"), "Ramparts went great.")["ok"] is True
    w.tick(2)
    assert call(gina, "AddNote", K("Aurelith"), "She joined our fishing derby.")["ok"] is True
    w.tick(5)
    for x in (gina, bob):
        n = [e["t"] for e in lst(person(x, "Aurelith")["n"])]
        assert n == ["She joined our fishing derby.", "Ramparts went great."], (x.name, n)
    # pass to a recruiter only
    assert call(gina, "PassTo", K("Aurelith"), K("Cora"))["ok"] is False
    assert call(gina, "PassTo", K("Aurelith"), K("Gina"))["ok"] is True
    w.tick(5)
    assert person(bob, "Aurelith")["w"] == K("Gina")
    # Not now, and back
    assert call(bob, "NotNow", K("Aurelith"))["ok"] is True
    w.tick(5)
    p = person(gina, "Aurelith")
    assert p["st"] == "notnow" and p["nn"] and p.get("fu") is None, p
    w.assert_no_errors()


@case
def an_officer_who_was_offline_catches_up_on_login():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    bob.logout()
    w.tick(2)
    add(gina, "Thalric", c="WARRIOR", sp=3)
    add(gina, "Nortok", c="SHAMAN", sp=3)
    w.tick(5)
    bob.login()
    w.tick(SETTLE)
    assert person(bob, "Thalric") and person(bob, "Nortok"), stored(bob)
    # and the other way: Bob noted something while Gina was away
    gina.logout()
    w.tick(2)
    call(bob, "AddNote", K("Thalric"), "Talked, he is lovely.")
    w.tick(2)
    gina.login()
    w.tick(SETTLE)
    assert [e["t"] for e in lst(person(gina, "Thalric")["n"])] == ["Talked, he is lovely."]
    w.assert_no_errors()


@case
def a_removal_wins_over_an_old_copy():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    add(gina, "Stabbystab", c="ROGUE", sp=2)
    w.tick(5)
    assert person(bob, "Stabbystab")
    bob.logout()
    w.tick(2)
    assert call(gina, "Remove", K("Stabbystab"))["ok"] is True
    w.tick(2)
    bob.login()                                   # Bob still holds the old copy
    w.tick(SETTLE)
    assert person(bob, "Stabbystab") is None, person(bob, "Stabbystab")
    assert person(gina, "Stabbystab") is None
    # re-adding later is fine (a newer revision than the tombstone)
    assert add(bob, "Stabbystab", c="ROGUE")["ok"] is True
    w.tick(5)
    assert person(gina, "Stabbystab")
    w.assert_no_errors()


@case
def a_hand_made_record_from_a_member_is_dropped():
    w, c = guild()
    gina, cora, pug = c["Gina"], c["Cora"], c["Darkstalkerr"]
    for x in (cora, pug):
        x.eval("local now = GetServerTime(); ns.Comm:Send({ t = 'RC', k = 'Forged-Thunderstrike', v = now, "
               "r = { st = 'talk', rev = now, c = 'MAGE' } }, 'WHISPER', 'Gina-Thunderstrike', 'data')")
    w.tick(5)
    assert person(gina, "Forged") is None and stored(gina) == []
    w.assert_no_errors()


@case
def an_officer_who_loses_the_rank_forgets_the_people():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    add(gina, "Kaelthorn", c="PALADIN", sp=1)
    w.tick(5)
    assert stored(bob) == [K("Kaelthorn")]
    bob.guild_rank = 3
    w._sync(roster_changed=True, guild=bob.guild)
    w.tick(15)
    assert stored(bob) == [], stored(bob)
    assert bob.eval("return ns.Recruit:CanUse()") is False
    add(gina, "Aurelith", c="PALADIN")
    w.tick(5)
    assert stored(bob) == []
    w.assert_no_errors()


@case
def the_gms_rules_sync_and_raid_leaders_work_on_recruits_when_allowed():
    w, c = guild()
    gina, bob, lee, cora = c["Gina"], c["Bob"], c["Lee"], c["Cora"]
    rules = lambda x: x.eval_py("return ns.Guild:GetRecruitRules()")
    assert rules(cora)["uc"] == 2 and rules(cora)["wk"]["l"] is False
    assert bob.eval_py("return { ns.Guild:SetRecruitRules({ uc = 5 }) }")[0] is False     # an officer can't
    assert gina.eval_py("return { ns.Guild:SetRecruitRules({ uc = 5, q = 21 }) }")[0] is True
    w.tick(5)
    for x in (bob, lee, cora):
        r = rules(x)
        assert r["uc"] == 5 and r["q"] == 21 and r["ck"] == 1, (x.name, r)
    # Lee is a listed raid leader: a recruiter only once the GM lets raid leaders work on recruits
    gina.eval("ns.Guild:SetRaidLeaders({ 'Lee-Thunderstrike' })")
    w.tick(5)
    assert lee.eval("return ns.Recruit:IsRecruiter(ns.Util.PlayerKey())") is False
    add(gina, "Kaelthorn", c="PALADIN")
    w.tick(5)
    assert stored(lee) == []
    gina.eval("ns.Guild:SetRecruitRules({ wk = { o = true, l = true } })")
    w.tick(5)
    assert lee.eval("return ns.Recruit:IsRecruiter(ns.Util.PlayerKey())") is True
    lee.eval("ns.Recruit:ShareNow()")
    w.tick(5)
    assert stored(lee) == [K("Kaelthorn")], stored(lee)
    # and back off: Lee forgets them
    gina.eval("ns.Guild:SetRecruitRules({ wk = { o = true, l = false } })")
    w.tick(10)
    assert stored(lee) == [], stored(lee)
    w.assert_no_errors()


@case
def the_fit_follows_team_nights_and_open_places():
    w, c = guild(extra_pug=False)
    gina = c["Gina"]
    res = gina.eval_py("""
        local ok, id = ns.RaidPlan:SaveTeam(nil, 'Main team', {}, { size = 10,
            comp = { PALADIN = { 1 } }, nights = { { w = %d, m = 210 }, { w = %d, m = 210, o = true } } })
        local ok2, id2 = ns.RaidPlan:SaveTeam(nil, 'Night Owls', {}, { size = 10, comp = { WARRIOR = { 0, 0, 1 } },
            nights = { { w = %d, m = 180 } } })
        return { ok = ok, id = id, ok2 = ok2, id2 = id2 }""" % (THU, SUN, TUE))
    assert res["ok"] and res["ok2"], res
    w.tick(3)

    def fits(nights, c_="PALADIN", sp=1):
        return gina.eval_py("""
            local r = { c = ..., sp = select(2, ...), ni = select(3, ...) }
            local out = {}
            local list, best = ns.Recruit:Fits(r)
            for _, f in ipairs(list) do out[f.team.name] = { ok = f.ok, nightsOk = f.nightsOk, part = f.part, place = f.place } end
            out.best = best and best.team.name or false
            return out""", c_, sp, nights)
    f = fits([4, 7])
    assert f["Main team"] == {"ok": True, "nightsOk": True, "part": False, "place": True}, f
    assert f["Night Owls"]["ok"] is False and f["Night Owls"]["nightsOk"] is False and f["best"] == "Main team", f
    f = fits([4])                                            # Sunday is optional: still fits
    assert f["Main team"]["ok"] is True, f
    f = fits([2])                                            # Tuesday: Night Owls' night, but no paladin place there
    assert f["Main team"]["nightsOk"] is False and f["Night Owls"]["nightsOk"] is True and f["Night Owls"]["place"] is False, f
    assert f["best"] is False
    f = fits([4, 7], sp=3)                                    # a Retribution paladin: Main wants a Holy one
    assert f["Main team"]["nightsOk"] is True and f["Main team"]["place"] is False, f
    f = fits([2, 4], "WARRIOR", 3)                            # a Protection warrior on Tue + Thu
    assert f["Night Owls"]["ok"] is True and f["best"] == "Night Owls", f
    assert gina.eval_py("return { ns.Recruit:Fits({ c = 'PALADIN', sp = 1 }) }")[0] in ({}, [], None)   # no nights: no fit
    w.assert_no_errors()


@case
def demo_mode_shows_made_up_people_to_anyone_and_sends_nothing():
    w, c = guild()
    gina, cora = c["Gina"], c["Cora"]
    cora.eval("ns.Demo:SetEnabled(true)")
    w.tick(2)
    assert cora.eval("return ns.Recruit:CanUse()") is True
    names = cora.eval_py("local out = {} for _, p in ipairs(ns.Recruit:GetPeople()) do out[#out + 1] = p.key:gsub('%-.*', '') end "
                         "table.sort(out) return out")
    assert names == ["Aurelith", "Bramble", "Darkstalkerr", "Fennick", "Kaelthorn", "Nortok", "Stabbystab", "Thalric"], names
    assert add(cora, "Tryme", c="MAGE")["ok"] is True
    assert call(cora, "AddNote", K("Tryme"), "demo note")["ok"] is True
    w.tick(5)
    assert stored(cora) == [] and stored(gina) == [] and person(gina, "Tryme") is None
    cora.eval("ns.Demo:SetEnabled(false)")
    w.tick(2)
    assert cora.eval("return ns.Recruit:CanUse()") is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
