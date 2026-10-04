"""Raid planning 1.3: guests, declined / removed answers, the blacklist, answering with another character, and the
invite run's "missing" lists.

Covers: a roster manager (GM, officer, raid leader) adding a player outside the guild as a guest (who counts as
accepted, is laid out and invited), members and the guild council (who don't plan raids) refused; declining a member (their answer no longer counts, they
can't answer again, listed apart) and removing an answer (they can answer again), with Restore; the guild's blacklist
(hard block: the sign-up is refused on the member's client and not counted when it arrives anyway, no guest seat, no
invite, only managers change it, it reaches a member who was offline); a player answering with another character of
their account (one answer per player, the newest counts, other players' characters refused); Invite & sort inviting
guests and the other players placed in a group (not those who accepted without one: they are named), skipping
blacklisted and declined ones, and telling who is missing.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_guests.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, team, create, raid, raids, signup, \
    signups, call  # noqa: E402
from _common import case, run_all, strip_codes, install_helpers, tt_lines  # noqa: E402

P = "ns.RaidsUI:GetPanel()"

# Gina = GM, Bob = guild council + raid leader, Olaf = an officer (rank 1) on no list, the others members.
NAMES = (("Gina", 0, "PALADIN", 70), ("Bob", 2, "MAGE", 70), ("Olaf", 1, "WARRIOR", 70), ("Lee", 3, "WARRIOR", 70),
         ("Rita", 3, "PRIEST", 70), ("Sam", 3, "ROGUE", 70))


def world(names=NAMES, pairs=()):
    w = World()
    c = {}
    for name, rank, cls, level in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, level=level)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    for main, alt in pairs:
        own(c[main], alt)
        own(c[alt], main)
    w.tick(50 if pairs else 2)      # everyone's own account entry goes out 25-45 s after login
    return w, c


def own(cl, *alts):
    """As if those characters had logged in on cl's account (the saved variables are per account)."""
    cl.eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
            "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; "
            "for _, k in ipairs({...}) do ns.db.accounts[gk].mine[k] = true end", *[K(a) for a in alts])


def block(cl, occ, name=None):
    return cl.eval("return ns.RaidPlan:GetSignupBlock(...)", occ, K(name) if name else None)


def forged_signup(cl, occ):
    """A sign-up sent past the local check (an older client, a tampered one)."""
    cl.eval("local o = ...; local _, c = UnitClass('player'); ns.Comm:Send({ t = 'RPS', l = { { o = o, "
            "s = { st = 'A', rev = GetServerTime() + 5, c = c } } } }, 'GUILD', nil, 'data')", occ)


def layout_members(cl, occ):
    return cl.eval_py("local out = {}; for _, m in ipairs(ns.RaidPlan:GetLayoutMembers(...)) do "
                      "out[m.key] = { st = m.st or 'none', guest = m.guest or false, c = m.c } end; return out", occ)


def open_tab(w, cl, occ=None):
    cl.slash("/dz raids")
    w.tick(0.5)
    if occ:
        cl.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
        w.tick(0.3)


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


ROSTER_CELL = """
  local key = ...
  local found
  ns.RaidsUI:GetPanel().upcoming.detail.roster.box:ForEachFrame(function(row)
    for _, cell in ipairs(row.cells or {}) do
      if cell:IsShown() and cell.cdlCell and cell.cdlCell.key == key then found = cell end
    end
  end)
  return found"""

RAID_ROW = """
  local occ = ...
  local found
  ns.RaidsUI:GetPanel().upcoming.list.box:ForEachFrame(function(row)
    local d = row.__cdlData
    if row:IsShown() and d and d.v and d.v.id == occ then found = row end
  end)
  return found"""


def has_line(cl, label, count):
    """A roster line "<label> (<n>)" (the label is colour-coded)."""
    for o in cl.find_text(label, True, True):
        t = strip_codes(cl.eval("local o = ...; return o:GetText()", o) or "")
        if label in t and count in t:
            return True
    return False


def listed(cl):
    """The raids in the Upcoming list, as drawn (ids)."""
    return list(cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.RaidsUI:GetPanel().upcoming.list:GetData() or {}) do
        if d.v then out[#out + 1] = d.v.id end
      end
      return out""") or [])


# ------------------------------------------------------------------------------------------------------------------
@case
def guests_count_as_accepted_and_only_managers_add_them():
    w, c = world()
    bob, olaf, lee, rita = c["Bob"], c["Olaf"], c["Lee"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(lee, occ, "A", 3)["ok"] is True
    res = call(bob, "AddGuest", occ, "Pugsy", "ROGUE", 2)
    assert res["ok"] is True and res["e"] == K("Pugsy"), res
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)
        assert sorted(s) == sorted([K("Lee"), K("Pugsy")]), (n, s)
        g = s[K("Pugsy")]
        assert g["st"] == "A" and g["guest"] is True and g["c"] == "ROGUE" and g["sp"] == 2, (n, g)
        assert x.eval("return ns.RaidPlan:IsGuest(...)", occ, K("Pugsy")) is True
        assert x.eval("return ns.RaidPlan:IsGuest(...)", occ, K("Lee")) is False
    m = layout_members(rita, occ)
    assert m[K("Pugsy")] == {"st": "A", "guest": True, "c": "ROGUE"}, m
    lay = rita.eval_py("return (ns.RaidPlan:GetLayout(...))", occ)
    assert K("Pugsy") in lay and K("Lee") in lay, lay            # the starting layout seats the guest
    # an officer who is on no list manages the roster too, and the raid stays listed for everyone
    assert olaf.eval("return ns.RaidPlan:CanManageRoster()") is True
    assert olaf.eval("return ns.RaidPlan:CanOrganize()") is False
    assert call(olaf, "AddGuest", occ, "Healbot", "PRIEST")["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert [v["id"] for v in raids(x)] == [occ], n
        assert sorted(x.eval_py("local o = {}; for k in pairs(ns.RaidPlan:GetGuests(...)) do o[#o + 1] = k end; "
                                "return o", occ)) == sorted([K("Healbot"), K("Pugsy")]), n
    # members can't; guild members are not guests; a class is needed
    assert lee.eval("return ns.RaidPlan:CanManageRoster()") is False
    assert call(lee, "AddGuest", occ, "Mate", "MAGE")["ok"] is False
    res = call(bob, "AddGuest", occ, "Rita", "PRIEST")
    assert res["ok"] is False and "guild" in res["e"], res
    assert call(bob, "AddGuest", occ, "Nope", "BARD")["ok"] is False
    assert call(bob, "AddGuest", occ, "", "MAGE")["ok"] is False
    assert call(bob, "AddGuest", occ, "Odd", "MAGE", 9)["ok"] is False
    # the guest's class or spec is changed by adding them again; removing takes them out of the groups too
    assert call(bob, "AddGuest", occ, "Pugsy", "ROGUE", 1)["ok"] is True
    assert call(bob, "SetGroups", occ, {K("Pugsy"): 1, K("Lee"): 1})["ok"] is True
    assert call(bob, "RemoveGuest", occ, K("Pugsy"))["ok"] is True
    w.tick(2)
    v = raid(rita, occ)
    assert K("Pugsy") not in (v.get("gu") or {}) and K("Pugsy") not in v["grp"] and K("Lee") in v["grp"], v
    assert K("Pugsy") not in signups(rita, occ)
    assert call(bob, "RemoveGuest", occ, K("Pugsy"))["ok"] is False
    # a malformed guest list from the network is refused whole
    bob.eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'zz9', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
             "t = GetServerTime() + 86400, i = 'za', sz = 10, gu = { ['X-Y'] = { c = 'BARD' } } } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert raid(rita, "zz9") is None
    w.assert_no_errors()


@case
def a_weekly_raid_gets_its_guests_for_one_week():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ0 = create(bob, i="ssc", t=now(bob) + DAY, weekly=True)
    occ1 = occ0.replace("#0", "#1")
    w.tick(2)
    assert call(bob, "AddGuest", occ1, "Pugsy", "HUNTER", 1)["ok"] is True
    w.tick(2)
    assert K("Pugsy") in signups(rita, occ1) and K("Pugsy") not in signups(rita, occ0)
    assert raid(rita, occ1)["t"] == raid(rita, occ0)["t"] + 7 * DAY or abs(
        raid(rita, occ1)["t"] - raid(rita, occ0)["t"] - 7 * DAY) <= 3600
    w.assert_no_errors()


@case
def declined_and_removed_answers():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Kara A", ["Lee", "Rita", "Sam"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    w.tick(2)
    for x in (lee, rita, sam):
        assert signup(x, occ, "A")["ok"] is True
    w.tick(2)
    assert call(bob, "SetGroups", occ, {K("Lee"): 1, K("Rita"): 1, K("Sam"): 1})["ok"] is True
    # declined: not counted, out of the groups, can't answer again, listed apart
    assert call(bob, "DeclineSignup", occ, K("Lee"))["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert sorted(signups(x, occ)) == sorted([K("Rita"), K("Sam")]), (n, signups(x, occ))
        d = x.eval_py("return ns.RaidPlan:GetDeclined(...)", occ)
        assert list(d) == [K("Lee")] and d[K("Lee")]["st"] == "A" and d[K("Lee")]["c"] == "WARRIOR", (n, d)
    assert K("Lee") not in raid(rita, occ)["grp"]
    assert K("Lee") not in layout_members(rita, occ)
    assert block(lee, occ) == "declined" and block(bob, occ, "Lee") == "declined"
    res = signup(lee, occ, "T")
    assert res["ok"] is False and "took you off" in res["e"], res
    assert lee.eval("return ns.RaidPlan:GetMySignup(...)", occ) is None
    assert [v["id"] for v in lee.eval_py("return ns.RaidPlan:GetUnanswered(7)")] == []
    forged_signup(lee, occ)
    w.tick(2)
    assert K("Lee") not in signups(bob, occ)
    # removed: as if they never answered; a new answer counts again
    assert call(bob, "RemoveSignup", occ, K("Rita"))["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert sorted(signups(x, occ)) == [K("Sam")], (n, signups(x, occ))
    assert K("Rita") not in raid(sam, occ)["grp"]
    assert block(rita, occ) is None
    assert [v["id"] for v in rita.eval_py("return ns.RaidPlan:GetUnanswered(7)")] == [occ]
    assert signup(rita, occ, "B")["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert signups(x, occ)[K("Rita")]["st"] == "B", n
    assert call(bob, "RemoveSignup", occ, K("Gina"))["ok"] is False      # no answer to remove
    # restore: the declined member's answer counts again
    assert call(bob, "RestoreSignup", occ, K("Lee"))["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert signups(x, occ)[K("Lee")]["st"] == "A", n
        assert x.eval_py("return ns.RaidPlan:GetDeclined(...)", occ) == {}, n
    assert signup(lee, occ, "T")["ok"] is True
    assert call(bob, "RestoreSignup", occ, K("Lee"))["ok"] is False
    # members can do none of it
    for fn in ("DeclineSignup", "RemoveSignup", "RestoreSignup"):
        assert call(sam, fn, occ, K("Rita"))["ok"] is False, fn
    w.assert_no_errors()


@case
def the_blacklist_blocks_every_raid():
    w, c = world()
    bob, olaf, lee, rita, sam = c["Bob"], c["Olaf"], c["Lee"], c["Rita"], c["Sam"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(lee, occ, "A")["ok"] is True and signup(rita, occ, "A")["ok"] is True
    assert call(bob, "AddGuest", occ, "Badpug", "MAGE")["ok"] is True
    w.tick(2)
    sam.logout()
    w.tick(1)
    res = call(bob, "SetBlacklisted", "Lee", "left mid-raid twice")
    assert res["ok"] is True and res["e"] == K("Lee"), res
    w.tick(2)
    assert call(olaf, "SetBlacklisted", "Badpug", None)["ok"] is True      # an officer, and a player outside the guild
    w.tick(3)
    for n in ("Gina", "Bob", "Olaf", "Lee", "Rita"):
        x = c[n]
        bl = x.eval_py("return ns.RaidPlan:GetBlacklist()")
        assert [e["key"] for e in bl] == [K("Badpug"), K("Lee")], (n, bl)
        assert bl[1]["reason"] == "left mid-raid twice" and bl[1]["by"] == K("Bob"), (n, bl)
        assert x.eval("return ns.RaidPlan:IsBlacklisted(...)", K("Lee")) is True
        # the answer given before and the guest are gone from the raid
        assert sorted(signups(x, occ)) == [K("Rita")], (n, signups(x, occ))
    assert block(lee, occ) == "blacklist"
    res = signup(lee, occ, "A")
    assert res["ok"] is False and "officer" in res["e"], res
    forged_signup(lee, occ)
    w.tick(2)
    assert K("Lee") not in signups(bob, occ)
    # a new raid: the same; and no guest seat
    occ2 = create(bob, i="gruul", t=now(bob) + 2 * DAY)
    w.tick(2)
    assert signup(lee, occ2, "A")["ok"] is False
    res = call(bob, "AddGuest", occ2, "Badpug", "MAGE")
    assert res["ok"] is False and "blacklist" in res["e"], res
    # only roster managers change it: a member's call is refused, a member's forged list ignored
    assert call(lee, "RemoveBlacklisted", K("Lee"))["ok"] is False
    assert call(rita, "SetBlacklisted", "Sam", "x")["ok"] is False
    lee.eval("ns.Comm:Send({ t = 'BLL', rev = GetServerTime() + 100, by = ns.Util.PlayerKey(), l = {} }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert rita.eval("return ns.RaidPlan:IsBlacklisted(...)", K("Lee")) is True
    assert call(bob, "SetBlacklisted", "Bob", "me")["ok"] is False
    assert call(bob, "SetBlacklisted", "a|b", "x")["ok"] is False
    # a member who was offline gets the list after logging in
    sam.login()
    w.tick(60)
    assert [e["key"] for e in sam.eval_py("return ns.RaidPlan:GetBlacklist()")] == [K("Badpug"), K("Lee")]
    assert sorted(signups(sam, occ)) == [K("Rita")]
    # taken off: the old answer counts again
    assert call(bob, "RemoveBlacklisted", K("Lee"))["ok"] is True
    w.tick(3)
    for n, x in c.items():
        assert x.eval("return ns.RaidPlan:IsBlacklisted(...)", K("Lee")) is False, n
        assert sorted(signups(x, occ)) == sorted([K("Lee"), K("Rita")]), n
    assert signup(lee, occ2, "A")["ok"] is True
    w.assert_no_errors()


ALT_NAMES = NAMES + (("Lalt", 4, "WARLOCK", 70), ("Tiny", 4, "DRUID", 12))


@case
def a_player_answers_with_another_character():
    w, c = world(ALT_NAMES, pairs=(("Lee", "Lalt"), ("Lee", "Tiny")))
    bob, lee, lalt, rita = c["Bob"], c["Lee"], c["Lalt"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY, ml=70)
    w.tick(2)
    chars = list(lee.eval_py("return ns.RaidPlan:GetMyCharacters()"))
    assert chars == [K("Lee"), K("Lalt"), K("Tiny")], chars
    assert rita.eval("return ns.Guild:SameAccount(...)", K("Lee"), K("Lalt")) is True
    assert rita.eval("return ns.Guild:SameAccount(...)", K("Rita"), K("Lalt")) is False
    # Lee, logged in on his warrior, signs his warlock up
    res = lee.eval_py("local ok, e = ns.RaidPlan:SignUp(...); return { ok = ok, e = e }", occ, "A", 3, "on my lock", K("Lalt"))
    assert res["ok"] is True, res
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)
        assert list(s) == [K("Lalt")], (n, s)
        assert s[K("Lalt")]["c"] == "WARLOCK" and s[K("Lalt")]["sp"] == 3 and s[K("Lalt")]["n"] == "on my lock", (n, s)
    # it is his answer on both characters
    for x in (lee, lalt):
        assert x.eval_py("return ns.RaidPlan:GetMySignup(...)", occ)["st"] == "A"
        assert x.eval("return ns.RaidPlan:GetMySignupCharacter(...)", occ) == K("Lalt")
    # one answer per player: the newest counts
    assert signup(lee, occ, "T", 3)["ok"] is True
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)
        assert list(s) == [K("Lee")] and s[K("Lee")]["st"] == "T", (n, s)
    assert signup(lalt, occ, "B")["ok"] is True                      # ... and from the alt itself
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)
        assert list(s) == [K("Lalt")] and s[K("Lalt")]["st"] == "B", (n, s)
    # the level rule holds for the character that answers
    res = lee.eval_py("local ok, e = ns.RaidPlan:SignUp(...); return { ok = ok, e = e }", occ, "A", None, None, K("Tiny"))
    assert res["ok"] is False and "level 70" in res["e"], res
    # somebody else's character is refused, on the client and when it arrives anyway
    res = rita.eval_py("local ok, e = ns.RaidPlan:SignUp(...); return { ok = ok, e = e }", occ, "A", None, None, K("Lalt"))
    assert res["ok"] is False and "not one of your characters" in res["e"], res
    rita.eval("local o, k = ...; ns.Comm:Send({ t = 'RPA', l = { { o = o, k = k, s = { st = 'X', "
              "rev = GetServerTime() + 50, c = 'WARLOCK' } } } }, 'GUILD', nil, 'data')", occ, K("Lalt"))
    w.tick(2)
    assert signups(bob, occ)[K("Lalt")]["st"] == "B"
    # a team names the main: the alt may answer a locked raid, and one answer is enough
    tid = team(bob, "Main", ["Lee"])
    locked = create(bob, i="gruul", t=now(bob) + 2 * DAY, tm=[tid], lk=True)
    w.tick(2)
    assert block(lalt, locked) is None and block(rita, locked) == "lock"
    assert [v["id"] for v in raids(lalt)] == [occ, locked]
    assert [v["id"] for v in lee.eval_py("return ns.RaidPlan:GetUnanswered(7)")] == [locked]
    assert signup(lalt, locked, "A")["ok"] is True
    w.tick(2)
    assert list(signups(bob, locked)) == [K("Lalt")]
    assert [v["id"] for v in lee.eval_py("return ns.RaidPlan:GetUnanswered(7)")] == []
    # a decline and the blacklist cover all the player's characters
    assert call(bob, "DeclineSignup", locked, K("Lalt"))["ok"] is True
    w.tick(2)
    assert block(lee, locked) == "declined" and signup(lee, locked, "A")["ok"] is False
    assert call(bob, "SetBlacklisted", "Lee", "no-show")["ok"] is True
    w.tick(3)
    assert block(bob, occ, "Lalt") == "blacklist" and block(bob, occ, "Tiny") == "blacklist"
    assert signups(rita, occ) == {}
    assert signup(lalt, occ, "A")["ok"] is False
    assert rita.eval_py("return ns.RaidPlan:GetBlacklistEntry(...)", K("Lalt"))["key"] == K("Lee")
    w.assert_no_errors()


@case
def invite_and_sort_takes_guests_and_tells_who_is_missing():
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Tank", 3, "WARRIOR"), ("Pip", 3, "PRIEST"),
                            ("Rog", 3, "ROGUE"), ("Bad", 3, "HUNTER"), ("Nay", 3, "DRUID"), ("Late", 3, "SHAMAN")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    c["Pug"] = Client(w, "Pug", guild=None, class_file="WARLOCK")
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    w.tick(2)
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    for n in ("Tank", "Pip", "Rog", "Bad", "Nay"):
        assert signup(c[n], occ, "A")["ok"] is True, n
    w.tick(2)
    assert call(bob, "AddGuest", occ, "Pug", "WARLOCK", 1)["ok"] is True
    assert call(bob, "AddGuest", occ, "Ghost", "MAGE", 1)["ok"] is True       # nobody by that name is online
    # Tank, the guest and Bad get a group; Pip and Rog accepted without one
    assert call(bob, "SetGroups", occ, {K("Tank"): 1, K("Pug"): 1, K("Bad"): 2, K("Nay"): 2, K("Ghost"): 2})["ok"] is True
    assert call(bob, "SetBlacklisted", "Bad", "ninja")["ok"] is True
    assert call(bob, "DeclineSignup", occ, K("Nay"))["ok"] is True
    w.tick(3)
    open_tab(w, bob, occ)
    bob.click(bob.eval("return %s.upcoming.detail.tabGroups" % P))
    w.tick(0.3)
    n0 = len(bob.chat_frame)
    bob.click(bob.eval("return %s.upcoming.detail.groups.inviteBtn" % P))
    w.tick(20)
    members = {m.name for m in w.group_members()}
    assert members == {"Bob", "Tank", "Pug"}, members                     # the groups are who has a spot
    said = [strip_codes(str(l)) for l in bob.chat_frame[n0:]]
    assert any("Not invited, no group: Pip, Rog" in l for l in said), said
    invited = {e["target"].split("-")[0] for e in w.invite_log}
    assert "Bad" not in invited and "Nay" not in invited, invited          # blacklisted / declined: never invited
    assert w.subgroup_of("Tank") == 1 and w.subgroup_of("Pug") == 1, (w.subgroup_of("Tank"), w.subgroup_of("Pug"))
    st = bob.eval_py("return ns.RaidInvite:GetStatus()")
    assert list(st["offline"]) == [K("Ghost")], st                         # "Cannot find player"
    assert list(st["declined"] or []) == [] and list(st["unlisted"] or []) == [], st
    # somebody declines, somebody is in a group already, somebody outside the roster is brought along
    w.auto_accept_invites = False
    bob.eval("ns.RaidInvite:Start(...)", occ, {K("Tank"): 1, K("Late"): 2, K("Ghost"): 2}, "Kara")
    w.tick(3)
    assert bob.eval("return ns.RaidInvite:OnSystemMessage(...)", "Late declines your group invitation.") is True
    assert bob.eval("return ns.RaidInvite:OnSystemMessage(...)", "Somebody declines your group invitation.") is False
    assert bob.eval("return ns.RaidInvite:OnSystemMessage(...)", "Late has joined the raid group.") is False
    st = bob.eval_py("return ns.RaidInvite:GetStatus()")
    assert list(st["declined"]) == [K("Late")] and list(st["offline"]) == [K("Ghost")], st
    assert list(st["unlisted"]) == [K("Pug")], st
    assert st["planned"] == 3 and st["inRaid"] == 1, st
    bob.eval("ns.RaidInvite:OnSystemMessage(...)", "Late is already in a group.")
    assert list(bob.eval_py("return ns.RaidInvite:GetStatus()")["grouped"]) == [K("Late")]
    # the Groups tab says so, and the Missing menu lists them with a way to invite again
    w.tick(1)
    assert shown(bob, P + ".upcoming.detail.groups.missingBtn")
    btn = bob.eval("return %s.upcoming.detail.groups.missingBtn" % P)
    assert strip_codes(bob.eval("return (...):GetText()", btn)) == "Missing (3)"
    texts = [e.get("text") for e in bob.dropdown_menu(btn)["children"]]
    assert "Offline or not found (1)" in texts and "Already in a group (1)" in texts, texts
    assert "In the raid, not on the roster (1)" in texts and "Invite the missing players again" in texts, texts
    w.assert_no_errors()


@case
def the_roster_marks_guests_and_managers_right_click():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(lee, occ, "A", 3)["ok"] is True and signup(rita, occ, "A", 2)["ok"] is True
    assert call(bob, "AddGuest", occ, "Pugsy", "ROGUE", 2)["ok"] is True
    w.tick(2)
    open_tab(w, bob, occ)
    install_helpers(bob)
    assert bob.find_text("3/10 accepted", True, True) and bob.find_text("1 guest", True, True)
    cell = bob.eval(ROSTER_CELL, K("Pugsy"))
    assert cell is not None and "(guest)" in strip_codes(bob.eval("return (...).fs:GetText()", cell))
    bob.hover(cell)
    lines = [strip_codes(l) for l, _ in tt_lines(bob)]
    bob.leave(cell)
    assert any("Guest" in l for l in lines) and "Right-click for options" in lines, lines
    # a guest: Remove guest
    bob.click(cell, "RightButton")
    texts = [e.get("text") for e in bob.last_menu()["children"] if e.get("text")]
    assert texts == ["Pugsy", "Remove guest", "Blacklist...", "Guest book..."], texts
    # a member: decline / remove the answer
    bob.click(bob.eval(ROSTER_CELL, K("Lee")), "RightButton")
    texts = [e.get("text") for e in bob.last_menu()["children"] if e.get("text")]
    assert texts == ["Lee", "Decline for this raid", "Remove their answer", "Blacklist..."], texts
    bob.menu_select("Decline for this raid")
    w.tick(2)
    assert K("Lee") not in signups(rita, occ)
    w.tick(0.5)
    assert has_line(bob, "Declined", "(1)") and bob.find_text("1 declined", True, True)
    cell = bob.eval(ROSTER_CELL, K("Lee"))
    bob.hover(cell)
    lines = [strip_codes(l) for l, _ in tt_lines(bob)]
    bob.leave(cell)
    assert "Declined by the raid leaders" in lines and "Had answered Accepted" in lines, lines
    bob.click(cell, "RightButton")
    bob.menu_select("Restore: their answer counts again")
    w.tick(2)
    assert K("Lee") in signups(rita, occ)
    # the declined member reads why on the strip; a plain member gets no menu and no Guests button
    assert call(bob, "DeclineSignup", occ, K("Lee"))["ok"] is True
    w.tick(2)
    open_tab(w, lee, occ)
    assert lee.find_text("The raid leaders took you off this raid.", True, True)
    assert lee.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is False
    assert not shown(lee, P + ".upcoming.detail.inviteBtn") and not shown(lee, P + ".guestsBtn")
    open_tab(w, rita, occ)
    before = rita.last_menu()
    rita.click(rita.eval(ROSTER_CELL, K("Rita")), "RightButton")
    assert rita.last_menu() == before
    w.assert_no_errors()


@case
def the_guests_and_blacklist_windows():
    w, c = world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(lee, occ, "A")["ok"] is True
    w.tick(2)
    open_tab(w, bob, occ)
    assert shown(bob, P + ".upcoming.detail.inviteBtn") and shown(bob, P + ".guestsBtn")
    # Add players (the icon at the top right of the raid): guild members to invite, and guests by name, class, spec
    bob.click(bob.eval("return %s.upcoming.detail.inviteBtn" % P))
    G = "ns.RaidPlanUI:GetInviteWindow()"
    assert shown(bob, G) and shown(bob, G + ".picker.frame") and not shown(bob, G + ".nameBox")   # one row at a time
    bob.click(bob.eval("return %s.guestTab" % G))
    assert shown(bob, G + ".nameBox") and not shown(bob, G + ".picker.frame")
    bob.type_text(bob.eval("return %s.nameBox" % G), "Pugsy")
    bob.click(bob.eval("return %s.addBtn" % G))
    assert "class" in bob.eval("return %s.err:GetText()" % G)              # no class picked yet
    labels = [e["text"] for e in bob.dropdown_menu(bob.eval("return %s.classDD" % G))["children"]]
    assert "Rogue" in labels and len(labels) == 9, labels
    bob.menu_select("Rogue")
    specs = [e["text"] for e in bob.dropdown_menu(bob.eval("return %s.specDD" % G))["children"]]
    assert specs == ["Assassination", "Combat", "Subtlety"], specs
    bob.menu_select("Combat")
    bob.click(bob.eval("return %s.addBtn" % G))
    w.tick(2)
    g = rita.eval_py("return ns.RaidPlan:GetGuests(...)", occ)
    assert list(g) == [K("Pugsy")] and g[K("Pugsy")]["c"] == "ROGUE" and g[K("Pugsy")]["sp"] == 2, g
    assert bob.eval("return %s.nameBox:GetText()" % G) == ""
    assert bob.find_text("Combat Rogue", True, True) and bob.find_text("1 guest", True, True)
    rows = bob.eval_py("return %s.list:GetData()" % G)
    assert [(r["key"], r.get("guest")) for r in rows] == [(K("Pugsy"), True)], rows
    # an officer who plans no raids adds guests there too, without the guild member search
    olaf = c["Olaf"]
    open_tab(w, olaf, occ)
    olaf.click(olaf.eval("return %s.upcoming.detail.inviteBtn" % P))
    assert shown(olaf, G + ".nameBox") and not shown(olaf, G + ".picker.frame") and not shown(olaf, G + ".guestTab")
    bob.eval("ns.RaidPlanUI:RemoveGuest(...)", K("Pugsy"))
    w.tick(2)
    assert rita.eval_py("return ns.RaidPlan:GetGuests(...)", occ) == {}
    # Blacklist: from the toolbar, or from a roster right-click with the name filled in
    bob.click(bob.eval(ROSTER_CELL, K("Lee")), "RightButton")
    bob.menu_select("Blacklist...")
    B = "ns.RaidPlanUI:GetBlacklistWindow()"
    assert shown(bob, B) and bob.eval("return %s.nameBox:GetText()" % B) == "Lee"
    bob.type_text(bob.eval("return %s.reasonBox" % B), "left without a word", True)
    w.tick(3)
    e = rita.eval_py("return ns.RaidPlan:GetBlacklistEntry(...)", K("Lee"))
    assert e and e["reason"] == "left without a word" and e["by"] == K("Bob"), e
    assert bob.find_text("left without a word", True, True)
    assert signups(rita, occ) == {}
    open_tab(w, lee, occ)
    assert lee.find_text("You can't sign up for raids. Contact an officer.", True, True)
    assert lee.eval("return %s.upcoming.statusBtns.A:IsEnabled()" % P) is False
    assert lee.eval("return ns.RaidPlanUI:OpenBlacklist()") is False
    bob.click(bob.eval("return %s.guestsBtn" % P))
    bob.eval("ns.RaidPlanUI:Unblacklist(...)", K("Lee"))
    w.tick(3)
    assert rita.eval("return ns.RaidPlan:IsBlacklisted(...)", K("Lee")) is False
    assert bob.find_text("Nobody is blacklisted.", True, True)
    w.assert_no_errors()


@case
def the_list_filters_and_the_hover_tooltip():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    kara = create(bob, i="kara", t=now(bob) + 3600, ti="Kara full clear, alts welcome", no="Bring pots")
    gruul = create(bob, i="gruul", t=now(bob) + 9 * DAY)
    kara2 = create(bob, i="kara", t=now(bob) + 20 * DAY)
    w.tick(2)
    assert signup(rita, kara, "T")["ok"] is True
    assert call(bob, "AddGuest", kara, "Pugsy", "ROGUE", 2)["ok"] is True
    w.tick(2)
    open_tab(w, rita)
    assert listed(rita) == [kara, gruul, kara2]
    # which raid
    labels = [e["text"] for e in rita.dropdown_menu(rita.eval("return %s.upcoming.raidDD" % P))["children"]]
    assert labels[:3] == ["All raids", "Karazhan", "Gruul's Lair"], labels
    rita.menu_select("Karazhan")
    w.tick(0.3)
    assert listed(rita) == [kara, kara2]
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") in (kara, kara2)
    # ... and when
    rita.dropdown_menu(rita.eval("return %s.upcoming.whenDD" % P))
    rita.menu_select("Today")
    w.tick(0.3)
    today = listed(rita)
    assert today in ([kara], []), today              # (a run near midnight puts the raid on tomorrow)
    rita.eval("ns.RaidPlanUI:SetFilter('kara', 'later')")
    w.tick(0.3)
    assert listed(rita) == [kara2]
    rita.eval("ns.RaidPlanUI:SetFilter('za', 'all')")
    w.tick(0.3)
    assert listed(rita) == [] and rita.find_text("No raids match the filters.", True, True)
    # a raid opened from elsewhere is never hidden by the filters
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", gruul)
    w.tick(0.3)
    assert list(rita.eval_py("return { ns.RaidPlanUI:GetFilter() }")) == ["all", "all"]
    assert listed(rita) == [kara, gruul, kara2]
    # hover: the whole raid, nothing cut off
    install_helpers(rita)
    row = rita.eval(RAID_ROW, kara)
    assert row is not None
    rita.hover(row)
    lines = [strip_codes(l) for l, _ in tt_lines(rita)]
    rita.leave(row)
    assert lines[0] == "Kara full clear, alts welcome (10)", lines
    assert "Karazhan" in lines and '"Bring pots"' in lines and "Planned by Bob" in lines, lines
    assert any(l.startswith("1/10 accepted · 1 guest · 1 tentative") for l in lines), lines
    assert "You: Tentative" in lines, lines
    w.assert_no_errors()


@case
def the_strip_answers_with_another_character():
    w, c = world(ALT_NAMES, pairs=(("Lee", "Lalt"), ("Lee", "Tiny")))
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY, ml=70)
    w.tick(2)
    open_tab(w, rita, occ)
    assert not shown(rita, P + ".upcoming.charDD")                         # one character: no picker
    open_tab(w, lee, occ)
    assert shown(lee, P + ".upcoming.charDD")
    dd = lee.eval("return %s.upcoming.charDD" % P)
    labels = [e["text"] for e in lee.dropdown_menu(dd)["children"]]
    assert labels == ["Lee (Warrior)", "Lalt (Warlock)"], labels              # Tiny is level 12: not offered
    lee.menu_select("Lalt (Warlock)")
    w.tick(0.3)
    specs = [e["text"] for e in lee.dropdown_menu(lee.eval("return %s.upcoming.specDD" % P))["children"]]
    assert specs == ["Affliction", "Demonology", "Destruction"], specs
    lee.menu_select("Destruction")
    lee.click(lee.eval("return %s.upcoming.statusBtns.A" % P))
    w.tick(2)
    s = signups(bob, occ)
    assert list(s) == [K("Lalt")] and s[K("Lalt")]["c"] == "WARLOCK" and s[K("Lalt")]["sp"] == 3, s
    assert lee.eval("return %s.upcoming.statusBtns.A.chosen" % P) is True
    assert strip_codes(lee.eval("return (...):GetText()", dd)) == "Lalt (Warlock)"
    # switching back moves the answer to the warrior
    lee.dropdown_menu(dd)
    lee.menu_select("Lee (Warrior)")
    w.tick(2)
    s = signups(bob, occ)
    assert list(s) == [K("Lee")] and s[K("Lee")]["st"] == "A" and s[K("Lee")]["c"] == "WARRIOR", s
    w.assert_no_errors()


@case
def the_guild_council_does_not_add_guests():
    # 2026-10-04: guests, the guest book and the blacklist belong to those who plan raids (GM, raid leaders) and the
    # officers; a guild council member who is neither keeps teams and groups only
    w, c = world(names=NAMES + (("Cara", 3, "DRUID", 70),))
    gm_pick(w, c["Gina"], ["Bob", "Cara"])
    w.tick(2)
    gina, cara = c["Gina"], c["Cara"]
    occ = create(gina, i="kara", t=now(gina) + DAY)
    w.tick(2)
    assert cara.eval("return ns.RaidPlan:CanManageTeams()") is True
    assert cara.eval("return ns.RaidPlan:CanEditGroups()") is True
    assert cara.eval("return ns.RaidPlan:CanManageRoster()") is False
    assert gina.eval("return ns.RaidPlan:IsRosterManager(...)", K("Cara")) is False
    assert gina.eval("return ns.RaidPlan:IsRosterManager(...)", K("Bob")) is True     # raid leader
    assert gina.eval("return ns.RaidPlan:IsRosterManager(...)", K("Olaf")) is True    # officer
    res = call(cara, "AddGuest", occ, "Pugsy", "ROGUE")
    assert res["ok"] is False and "raid leaders" in (res.get("e") or ""), res
    open_tab(w, cara, occ)
    assert not shown(cara, P + ".guestsBtn")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
