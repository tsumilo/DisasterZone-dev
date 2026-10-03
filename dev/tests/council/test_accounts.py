"""Accounts: a player's characters share their roles (Core/Guild.lua, "Accounts").

Covers: a character vouching for the other characters of its account after login, the alt of the GM / a guild council
member / an officer / a listed raid leader having that role on every client (and using it: the council list, the raid
leaders list, a raid), roles not passing on twice, made-up vouches being refused (a member vouching "as" someone else,
a member naming itself an alt of the GM, a council member or an officer passing on a vouch of somebody above them),
a member who was offline learning the vouches from an officer, and /dz account.

Run: luaenv\\Scripts\\python.exe tests\\council\\test_accounts.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, create, raid  # noqa: E402
from _common import case, run_all  # noqa: E402

NAMES = (("Gina", 0, "PALADIN"), ("Galt", 4, "MAGE"),        # the GM and her alt
         ("Olaf", 1, "WARRIOR"), ("Oalt", 4, "ROGUE"),       # an officer and his alt
         ("Cara", 3, "PRIEST"), ("Calt", 4, "DRUID"),        # a guild council member and her alt
         ("Rex", 3, "HUNTER"), ("Ralt", 4, "SHAMAN"),        # a listed raid leader and his alt
         ("Lee", 4, "WARRIOR"), ("Lalt", 4, "WARLOCK"))      # a member and his alt
PAIRS = (("Gina", "Galt"), ("Olaf", "Oalt"), ("Cara", "Calt"), ("Rex", "Ralt"), ("Lee", "Lalt"))


def own(cl, *alts):
    """As if those characters had logged in on cl's account (the saved variables are per account)."""
    cl.eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
            "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; "
            "for _, k in ipairs({...}) do ns.db.accounts[gk].mine[k] = true end", *[K(a) for a in alts])


def world(pairs=PAIRS, names=NAMES):
    w = World()
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Cara"])
    set_raid_leaders(w, c["Gina"], ("Rex",))
    for main, alt in pairs:
        own(c[main], alt)
        own(c[alt], main)
    w.tick(50)          # everyone's own entry goes out 25-45 s after login
    return w, c


def roles(cl, name):
    return cl.eval_py("local k = ...; local G = ns.Guild; return { gm = G:IsGM(k), council = G:IsGuildCouncil(k), "
                      "officer = G:IsOfficer(k, true), planner = G:IsRaidPlanner(k), src = G:GetCouncilSource(k) }",
                      K(name))


def forge(cl, voucher, alts, rev_ahead=0):
    cl.eval("local k, m, d = ...; ns.Comm:Send({ t = 'ACB', l = { { k = k, v = GetServerTime() + d, m = m } } }, "
            "'GUILD', nil, 'ctrl')", K(voucher), [K(a) for a in alts], rev_ahead)


# ------------------------------------------------------------------------------------------------------------------
@case
def alts_have_the_roles_of_their_mains():
    w, c = world()
    for viewer in ("Lee", "Gina", "Calt", "Olaf"):
        v = c[viewer]
        r = roles(v, "Galt")
        assert r["gm"] and r["council"] and r["planner"] and r["src"] == "gm", (viewer, r)
        r = roles(v, "Calt")
        assert r["council"] and not r["gm"] and not r["officer"] and not r["planner"] and r["src"] == "guild", (viewer, r)
        r = roles(v, "Oalt")
        assert r["officer"] and not r["gm"] and not r["council"], (viewer, r)
        r = roles(v, "Ralt")
        assert r["planner"] and not r["officer"] and not r["council"], (viewer, r)
        r = roles(v, "Lalt")
        assert not (r["gm"] or r["council"] or r["officer"] or r["planner"]), (viewer, r)
        # the mains are what they were, and a main gets nothing from its alt
        assert roles(v, "Lee") == roles(v, "Lalt")
        assert v.eval("return ns.Guild:GetGM()") == K("Gina")
        members = list(v.eval_py("return ns.Guild:GetCouncilMembers()"))
        assert sorted(members) == sorted(K(n) for n in ("Gina", "Galt", "Cara", "Calt")), (viewer, members)
        assert list(v.eval_py("return ns.Guild:GetAccountMains(...)", K("Galt"))) == [K("Gina")]
    assert c["Galt"].eval("return ns.Guild:AmICouncil(true)") is True
    assert c["Galt"].eval("return ns.Guild:CanEditGuildCouncil()") is True
    assert c["Calt"].eval("return ns.Guild:CanEditGuildCouncil()") is False
    assert c["Oalt"].eval("return ns.Guild:CanEditRaidLeaders()") is True
    assert c["Ralt"].eval("return ns.RaidPlan:CanOrganize()") is True
    assert c["Lalt"].eval("return ns.RaidPlan:CanOrganize()") is False
    w.assert_no_errors()


@case
def alts_use_the_roles():
    w, c = world()
    lee = c["Lee"]
    # the GM's alt changes the guild council: everyone takes the list
    res = c["Galt"].eval_py("local ok, e = ns.Guild:SetGuildCouncil({...}, 2); return { ok = ok, e = e }",
                            K("Cara"), K("Lee"))
    assert res["ok"] is True, res
    w.tick(3)
    for x in (lee, c["Gina"], c["Olaf"], c["Lalt"]):
        g = x.eval_py("return ns.Guild:GetGuildCouncil()")
        assert sorted(g["members"]) == sorted([K("Cara"), K("Lee")]) and g["phase"] == 2 and g["by"] == K("Galt"), g
    assert roles(c["Olaf"], "Lalt")["council"] is True          # ... and Lee's alt is council with him
    # the officer's alt changes the raid leaders
    res = c["Oalt"].eval_py("local ok, e = ns.Guild:SetRaidLeaders({...}); return { ok = ok, e = e }", K("Rex"), K("Cara"))
    assert res["ok"] is True, res
    w.tick(3)
    assert list(lee.eval_py("return ns.Guild:GetRaidLeaders()")) == sorted([K("Cara"), K("Rex")])
    assert roles(lee, "Calt")["planner"] is True
    # the raid leader's alt plans a raid: every member has it
    occ = create(c["Ralt"], i="kara", t=now(c["Ralt"]) + DAY)
    w.tick(3)
    for x in (lee, c["Gina"], c["Lalt"]):
        v = raid(x, occ)
        assert v is not None and v["by"] == K("Ralt"), v
    # a member's alt can't
    res = c["Lalt"].eval_py("local ok, e = ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 86400 }); "
                            "return { ok = ok, e = e }")
    assert res["ok"] is False
    w.assert_no_errors()


@case
def made_up_vouches_are_refused():
    w, c = world(pairs=())
    lee, cara, olaf, gina = c["Lee"], c["Cara"], c["Olaf"], c["Gina"]
    plain = roles(olaf, "Lee")
    assert not (plain["gm"] or plain["council"] or plain["officer"] or plain["planner"])
    # a member "passes on" a vouch of the GM, of an officer, of a council member for itself
    for voucher in ("Gina", "Olaf", "Cara", "Rex"):
        forge(lee, voucher, ["Lee"], 30)
    # a member vouching for the GM gives the member nothing (roles go from the voucher to the vouched, never back)
    forge(lee, "Lee", ["Gina", "Olaf"])
    w.tick(3)
    for x in (olaf, cara, gina, c["Rex"], lee):
        assert roles(x, "Lee") == plain, roles(x, "Lee")
        assert x.eval("return ns.Guild:IsGM(...)", K("Gina")) is True
    # a council member passes on a made-up vouch of the GM and of an officer: refused (it holds neither role)
    forge(cara, "Gina", ["Calt"], 30)
    forge(cara, "Olaf", ["Calt"], 30)
    # an officer passes on a made-up vouch of the GM and of a council member: refused too
    forge(olaf, "Gina", ["Oalt"], 30)
    forge(olaf, "Cara", ["Oalt"], 30)
    w.tick(3)
    for x in (lee, c["Rex"], c["Lalt"]):
        r = roles(x, "Calt")
        assert not (r["gm"] or r["officer"] or r["council"]), r
        r = roles(x, "Oalt")
        assert not (r["gm"] or r["officer"] or r["council"]), r
    # a passed-on entry the vouching character's own client doesn't agree with is taken back by that client
    # (the offline case, where passing on is what spreads the entries, is its own test below)
    forge(olaf, "Rex", ["Ralt"], 50)
    w.tick(1)
    assert roles(c["Lalt"], "Ralt")["planner"] is True
    w.tick(4)
    assert roles(c["Lalt"], "Ralt")["planner"] is False
    # roles are not passed on twice: the alt of the GM's alt is nobody
    forge(gina, "Gina", ["Galt"], 50)
    forge(c["Galt"], "Galt", ["Lalt"])
    w.tick(3)
    assert roles(olaf, "Galt")["gm"] is True
    assert roles(olaf, "Lalt")["gm"] is False and roles(olaf, "Lalt")["council"] is False
    # malformed entries
    lee.eval("ns.Comm:Send({ t = 'ACB', l = { { k = 'a|b', v = 5, m = {} }, { k = ns.Util.PlayerKey(), v = 'x', m = {} }, "
             "{ k = ns.Util.PlayerKey(), v = GetServerTime() + 99999, m = { 'Olaf-Thunderstrike' } }, 7 } }, 'GUILD', nil, 'ctrl')")
    lee.eval("ns.Comm:Send({ t = 'ACB', l = 'x' }, 'GUILD', nil, 'ctrl')")
    w.tick(2)
    w.assert_no_errors()


@case
def a_member_who_was_offline_learns_from_an_officer():
    w, c = world(pairs=())
    lee = c["Lee"]
    lee.logout()
    w.tick(2)
    for main, alt in PAIRS[:4]:
        own(c[main], alt)
        c[main].eval("ns.Guild:GetMyCharacters()")
    # the mains speak while Lee is away, then go offline themselves
    for main in ("Gina", "Cara", "Rex", "Olaf"):
        forge(c[main], main, [dict(PAIRS)[main]])
    w.tick(3)
    assert roles(c["Oalt"], "Galt")["gm"] is True
    for main in ("Gina", "Cara", "Rex"):
        c[main].logout()
    w.tick(2)
    lee.login()
    w.tick(60)
    # Olaf (an officer, not council) passes on the raid leader's vouch and his own; not the GM's or the council
    # member's, which Lee takes from them alone (or from someone who holds those roles)
    assert roles(lee, "Ralt")["planner"] is True
    assert roles(lee, "Oalt")["officer"] is True
    assert roles(lee, "Galt")["gm"] is False and roles(lee, "Calt")["council"] is False
    # the GM comes back: her own entry reaches Lee
    c["Gina"].login()
    w.tick(60)
    assert roles(lee, "Galt")["gm"] is True
    w.assert_no_errors()


@case
def slash_account_and_forgetting_a_character():
    w, c = world(pairs=(("Gina", "Galt"),))
    gina, lee = c["Gina"], c["Lee"]
    n0 = len(gina.chat_frame)
    gina.slash("/dz account")
    assert any("share their roles: Galt" in l for l in gina.chat_frame[n0:]), gina.chat_frame[n0:]
    n0 = len(c["Galt"].chat_frame)
    c["Galt"].slash("/dz account")
    assert any("has the roles of: Gina" in l for l in c["Galt"].chat_frame[n0:]), c["Galt"].chat_frame[n0:]
    assert roles(lee, "Galt")["gm"] is True
    gina.slash("/dz account forget Galt")
    w.tick(3)
    assert roles(lee, "Galt")["gm"] is False and roles(c["Galt"], "Galt")["gm"] is False
    assert list(gina.eval_py("return ns.Guild:GetMyCharacters()") or []) == []
    n0 = len(lee.chat_frame)
    lee.slash("/dz account")
    assert any("No other character" in l for l in lee.chat_frame[n0:])
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
