"""Raid planning 1.3: raids stay the same for everyone when roles change, and hand-made messages don't change them
(user decisions 2026-10-04).

Covers: a raid whose leader's namer leaves the raid leaders list (the leader stops leading, the raid stays listed and
identical everywhere: a raid planner writes it again, also for a client that gets it fresh or had an older copy, once);
a leader named while a member was away reaching them through a raid planner's copy; made-up leaders (an officer, a
member crowning themselves) refused where the raid is known; made-up deletions (a member, an officer, the council, a copy
of the same version) neither hiding a raid nor wiping its sign-ups; the guild council not writing a led raid; a version
refused while the guild's lists were on their way taken once they arrive; a week's own leader editing and cancelling
that week but not deleting it, nor touching the whole weekly raid (core and the Cancel menu / Edit window); a deletion
that doesn't show never being built on; officers seeing locked raids (lists, the guest book's "Add as a guest to"); the
Home tab's next-raid card (answer buttons blocked with the reason, an answer given with another character, who still
has to answer).

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_trust.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, world as rp_world, set_raid_leaders, K, DAY, now, team, create, raid, \
    raids, signup, signups, call  # noqa: E402
from _common import case, run_all, strip_codes, menu_texts  # noqa: E402

P = "ns.RaidsUI:GetPanel()"


def world():
    """Gina = GM, Bob = guild council (rank 2: not an officer), Olaf = an officer on no list, Lee / Rita = on the raid
    leaders list, Sam / Vic / Una = members."""
    return rp_world(names=(("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Olaf", 1, "WARRIOR"), ("Lee", 3, "WARRIOR"),
                           ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"), ("Vic", 3, "HUNTER"), ("Una", 3, "SHAMAN")),
                    council=("Bob",), planners=("Lee", "Rita"))


def can(cl, fn, *args):
    return cl.eval("local fn = ...; return ns.RaidPlan[fn](ns.RaidPlan, select(2, ...))", fn, *args)


def lead(cl, occ, name, scope=None):
    return call(cl, "EditRaid", occ, {"rl": K(name) if name else False}, scope)


def stored(cl, kind, rid):
    return cl.eval_py("local k, id = ...; local r = ns.db.raidplan and ns.db.raidplan[ns.Guild:GetGuildKey()]; "
                      "return r and r[k][id]", kind, rid)


def forge(cl, occ, **fields):
    """A hand-made live edit of a raid's record (RPU) from cl, built on cl's stored copy: newer, by cl."""
    cl.eval("local o, f = ...; local r = ns.db.raidplan[ns.Guild:GetGuildKey()]; local e = {}; "
            "local sid, wk = o:match('^(%w+)#(%d+)$'); wk = tonumber(wk); "
            "for k, v in pairs(r.E[o] or { id = o, sid = sid, k = wk }) do e[k] = v end; "
            "for k, v in pairs(f) do e[k] = v end; "
            "if f.del then e = { id = o, sid = sid, k = wk, del = true, rl = f.rl, rlb = f.rlb } end; "
            "e.rev, e.by = GetServerTime() + 1, ns.Util.PlayerKey(); "
            "ns.Comm:Send({ t = 'RPU', k = 'E', r = e }, 'GUILD', nil, 'data')", occ, fields)


def fresh_logout(cl):
    """Logs out without any raid data saved: the next login is a fresh install for raid planning."""
    cl.eval("ns.db.raidplan = nil")
    cl.logout()


# ------------------------------------------------------------------------------------------------------------------
@case
def a_raid_stays_the_same_everywhere_after_its_leaders_namer_leaves_the_list():
    w, c = world()
    gina, bob, lee, rita, sam, vic, una = (c[n] for n in ("Gina", "Bob", "Lee", "Rita", "Sam", "Vic", "Una"))
    occ = create(lee, i="kara", t=now(lee) + DAY)
    wk = create(lee, i="ssc", t=now(lee) + 2 * DAY, weekly=True)
    w.tick(2)
    una.logout()                               # away: had the raids, misses the rest
    fresh_logout(vic)                          # comes back with a fresh install
    w.tick(1)
    assert lead(lee, occ, "Sam")["ok"] is True
    w.tick(2)
    assert call(sam, "EditRaid", occ, {"no": "Sam's note"})["ok"] is True
    w.tick(2)
    # the GM takes Lee off the raid leaders list: Sam stops leading, Lee's raids stay
    set_raid_leaders(w, gina, ("Rita",))
    for x in (gina, bob, rita, sam):
        v = raid(x, occ)
        assert v is not None and v.get("rl") is None and v["no"] == "Sam's note", (x.name, v)
    assert not can(sam, "CanManageRaid", occ)
    # a raid planner writes both again as their own, once
    w.tick(150)
    v0 = raid(rita, occ)
    assert v0["by"] in (K("Gina"), K("Rita")) and v0["no"] == "Sam's note" and v0.get("rl") is None, v0
    s0 = stored(rita, "S", wk.split("#")[0])
    assert s0["by"] in (K("Gina"), K("Rita")), s0
    for x in (gina, bob, lee, rita, sam):
        v = raid(x, occ)
        assert (v["rev"], v["by"], v["no"], v.get("rl")) == (v0["rev"], v0["by"], v0["no"], None), (x.name, v)
        assert stored(x, "S", wk.split("#")[0])["rev"] == s0["rev"], x.name
    # the member who was away and the fresh install get the same raids, and can sign up
    una.login()
    vic.login()
    w.tick(60)
    for x in (una, vic):
        v = raid(x, occ)
        assert v is not None and (v["rev"], v["by"], v["no"], v.get("rl")) == (v0["rev"], v0["by"], v0["no"], None), \
            (x.name, v)
        assert wk in [r["id"] for r in raids(x)], (x.name, raids(x))
        assert signup(x, occ, "A")["ok"] is True, x.name
    # nothing more to write
    revs = {x.name: stored(x, "E", occ)["rev"] for x in c.values()}
    for x in c.values():
        x.eval("ns:Fire('CONFIG_UPDATED')")
    w.tick(120)
    assert {x.name: stored(x, "E", occ)["rev"] for x in c.values()} == revs
    w.assert_no_errors()


@case
def a_leader_named_while_a_member_was_away_reaches_them_and_made_up_leaders_do_not():
    w, c = world()
    lee, olaf, sam, vic, una, rita = (c[n] for n in ("Lee", "Olaf", "Sam", "Vic", "Una", "Rita"))
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    una.logout()
    w.tick(1)
    assert lead(lee, occ, "Vic")["ok"] is True
    w.tick(2)
    assert call(vic, "EditRaid", occ, {"no": "Vic's note"})["ok"] is True
    w.tick(2)
    # Una gets Vic's version from whoever answers first; a raid planner's copy vouches for the leader
    una.login()
    w.tick(60)
    v = raid(una, occ)
    assert v["rl"] == K("Vic") and v["no"] == "Vic's note", v
    # an officer names a leader "named by" a raid leader; a member crowns themselves: refused where the raid is known
    forge(olaf, occ, rl=K("Olaf"), rlb=K("Lee"))
    forge(sam, occ, rl=K("Sam"), rlb=K("Lee"), no="mine now")
    w.tick(70)
    for x in c.values():
        v = raid(x, occ)
        assert v["rl"] == K("Vic") and v["no"] == "Vic's note", (x.name, v)
    assert not can(sam, "CanManageRaid", occ) and not can(olaf, "CanManageRaid", occ)
    assert can(vic, "CanManageRaid", occ) and can(rita, "CanManageRaid", occ)
    w.assert_no_errors()


@case
def made_up_deletions_neither_hide_a_raid_nor_wipe_its_signups():
    w, c = world()
    lee, bob, olaf, sam, vic, rita = (c[n] for n in ("Lee", "Bob", "Olaf", "Sam", "Vic", "Rita"))
    occ = create(lee, i="kara", t=now(lee) + DAY, no="Lee's note")
    w.tick(2)
    assert signup(sam, occ, "A", 1)["ok"] is True and signup(vic, occ, "T", 1)["ok"] is True
    w.tick(2)
    # a member, an officer and the council: none of them deletes raids
    for x in (sam, olaf, bob):
        forge(x, occ, **{"del": True})
        w.tick(2)
        for y in c.values():
            assert raid(y, occ) is not None, (x.name, y.name)
            assert sorted(signups(y, occ)) == [K("Sam"), K("Vic")], (x.name, y.name)
    # a copy of the same version by someone else (made to win the same-rev tie) doesn't take the version's trust
    res = sam.eval_py("local o = ...; local root = ns.db.raidplan[ns.Guild:GetGuildKey()]; local e = root.E[o]; "
                      "local h = ns.Util.Hash(e); for i = 1, 200 do local copy = {}; "
                      "for k, v in pairs(e) do copy[k] = v end; copy.by = ns.Util.PlayerKey(); "
                      "copy.no = string.rep('~', 60 + i % 60) .. i; if ns.Util.Hash(copy) > h then return copy end end", occ)
    assert res is not None
    sam.eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = ... }, 'GUILD', nil, 'data')", res)
    w.tick(2)
    for y in c.values():
        assert raid(y, occ)["no"] == "Lee's note", y.name
    # a sign-up still works; a real deletion by a raid leader takes the raid and its sign-ups everywhere
    assert signup(rita, occ, "B", 1)["ok"] is True
    w.tick(2)
    assert call(lee, "DeleteRaid", occ)["ok"] is True
    w.tick(2)
    for y in c.values():
        assert raid(y, occ) is None and signups(y, occ) == {}, y.name
    w.assert_no_errors()


@case
def the_council_does_not_write_a_led_raid_and_officers_keep_its_guests():
    w, c = world()
    lee, bob, olaf, rita = (c[n] for n in ("Lee", "Bob", "Olaf", "Rita"))
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    assert lead(lee, occ, "Sam")["ok"] is True
    w.tick(2)
    forge(bob, occ, grp={K("Bob"): 1})
    w.tick(2)
    for x in c.values():
        assert raid(x, occ).get("grp") is None, x.name
    assert call(olaf, "AddGuest", occ, "Pugzor", "MAGE", 1)["ok"] is True
    w.tick(2)
    for x in c.values():
        assert K("Pugzor") in raid(x, occ)["gu"], x.name
    w.assert_no_errors()


@case
def a_version_refused_while_the_lists_were_on_their_way_is_taken_once_they_arrive():
    w, c = world()
    gina, lee, vic, una = c["Gina"], c["Lee"], c["Vic"], c["Una"]
    occ = create(lee, i="kara", t=now(lee) + DAY)
    w.tick(2)
    set_raid_leaders(w, gina, ("Lee", "Rita", "Vic"))
    # Una's list doesn't name Vic yet
    una.eval("ns.db.raidLeaders[ns.Guild:GetGuildKey()].m[...] = nil", K("Vic"))
    assert call(vic, "EditRaid", occ, {"no": "Vic's note"})["ok"] is True
    w.tick(2)
    assert raid(una, occ).get("no") is None
    una.eval("ns.db.raidLeaders[ns.Guild:GetGuildKey()].m[...] = true; ns:Fire('CONFIG_UPDATED')", K("Vic"))
    w.tick(1)
    assert raid(una, occ)["no"] == "Vic's note"
    w.assert_no_errors()


@case
def a_weeks_own_leader_edits_and_cancels_that_week_but_does_not_delete_it():
    w, c = world()
    lee, sam, vic, una, rita = (c[n] for n in ("Lee", "Sam", "Vic", "Una", "Rita"))
    occ0 = create(lee, i="ssc", t=now(lee) + DAY, weekly=True)
    sid = occ0.split("#")[0]
    occ1, occ2 = sid + "#1", sid + "#2"
    w.tick(2)
    assert lead(lee, occ1, "Vic", "one")["ok"] is True
    w.tick(2)
    assert signup(sam, occ1, "A", 1)["ok"] is True
    w.tick(2)
    assert can(vic, "CanManageRaid", occ1) and not can(vic, "CanDeleteRaid", occ1)
    assert not can(vic, "CanManageSeries", occ1) and not can(vic, "CanDeleteRaid", occ1, "series")
    res = call(vic, "DeleteRaid", occ1)
    assert res["ok"] is False and "cancel it, not delete it" in res["e"], res
    for fn, args in (("StopRepeating", ()), ("EditRaid", ({"no": "x"}, "series")), ("CancelRaid", ("series",))):
        assert call(vic, fn, occ1, *args)["ok"] is False, fn
    assert call(vic, "EditRaid", occ1, {"no": "Vic's week"}, "one")["ok"] is True
    assert call(vic, "CancelRaid", occ1)["ok"] is True
    w.tick(2)
    assert raid(rita, occ1)["cancelled"] is True
    assert call(vic, "EditRaid", occ1, {"x": False})["ok"] is True
    w.tick(2)
    for x in c.values():
        v = raid(x, occ1)
        assert v["rl"] == K("Vic") and v["no"] == "Vic's week" and not v["cancelled"], (x.name, v)
        assert list(signups(x, occ1)) == [K("Sam")], x.name
    # the Cancel menu and the Edit window offer only what Vic may do
    vic.slash("/dz raids")
    w.tick(0.5)
    vic.eval("ns.RaidPlanUI:SelectRaid(...)", occ1)
    w.tick(0.3)
    btn = vic.eval("return %s.upcoming.detail.cancelBtn" % P)
    entries = [e["text"] for e in vic.dropdown_menu(btn)["children"] if e.get("text")]
    assert entries == ["Cancel this week's raid"], entries
    vic.eval("ns.RaidPlanUI:OpenEditor(...)", occ1)
    assert vic.eval("return ns.RaidPlanUI:GetEditor():IsShown()")
    assert not vic.eval("return ns.RaidPlanUI:GetEditor().saveAllBtn:IsShown()")
    assert not vic.eval("return ns.RaidPlanUI:GetEditor().weeklyInfo:IsShown()")
    vic.eval("ns.RaidPlanUI:GetEditor():Hide()")
    # the weekly raid's own leader deletes a week of it (and runs the whole series)
    assert lead(lee, occ0, "Sam", "series")["ok"] is True
    w.tick(2)
    assert can(sam, "CanDeleteRaid", occ0) and can(sam, "CanManageSeries", occ0)
    sam.slash("/dz raids")
    w.tick(0.5)
    sam.eval("ns.RaidPlanUI:SelectRaid(...)", occ0)
    w.tick(0.3)
    btn = sam.eval("return %s.upcoming.detail.cancelBtn" % P)
    entries = [e["text"] for e in sam.dropdown_menu(btn)["children"] if e.get("text")]
    assert entries == ["Cancel this week's raid", "Stop repeating after this raid", "Delete this week's raid...",
                       "Delete the whole weekly raid..."], entries
    assert call(sam, "DeleteRaid", occ0)["ok"] is True
    w.tick(2)
    for x in c.values():
        ids = [r["id"] for r in raids(x)]
        assert occ0 not in ids and occ1 in ids, (x.name, ids)
    # a made-up deletion of week 2 doesn't show, takes sign-ups, and an edit doesn't build on it
    forge(una, occ2, **{"del": True})
    w.tick(2)
    assert signup(una, occ2, "A", 1)["ok"] is True
    assert call(lee, "EditRaid", occ2, {"no": "Lee's week"}, "one")["ok"] is True
    w.tick(2)
    for x in c.values():
        v = raid(x, occ2)
        assert v is not None and v["no"] == "Lee's week", (x.name, v)
        assert K("Una") in signups(x, occ2), x.name
    w.assert_no_errors()


@case
def officers_see_locked_raids_and_can_add_their_guests():
    w, c = world()
    bob, lee, olaf, una = c["Bob"], c["Lee"], c["Olaf"], c["Una"]
    tid = team(bob, "Core", ["Rita", "Sam"])
    w.tick(2)
    occ = create(lee, i="kara", t=now(lee) + DAY, tm=[tid], lk=True)
    w.tick(2)
    assert occ in [v["id"] for v in raids(olaf)] and olaf.eval("return ns.RaidPlan:CanSee(...)", occ)
    assert occ not in [v["id"] for v in raids(una)]
    # the guest book's "Add as a guest to" lists it
    res = olaf.eval_py("local ok, k = ns.GuestBook:SetNote('Pugzor', 'tank'); return { ok = ok, k = k }")
    assert res["ok"] is True, res
    w.tick(1)
    olaf.eval("ns.GuestBookUI:OpenEntryMenu(UIParent, ns.GuestBook:GetEntry(...))", K("Pugzor"))
    texts = [strip_codes(t[2] or "") for t in menu_texts(olaf.last_menu())]
    assert "Add as a guest to" in texts and any("Karazhan" in t for t in texts), texts
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Home tab: the next raid's card

def home_texts(cl):
    lines = cl.eval_py("""
      local out = {}
      local p = ns.Dashboard:GetPanel()
      if not p or not p:IsVisible() then return out end
      local function walk(f)
        for _, r in ipairs({ f:GetRegions() }) do
          if r.GetText and r:IsVisible() and r:GetText() and r:GetText() ~= "" then out[#out + 1] = r:GetText() end
        end
        for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() then walk(ch) end end
      end
      walk(p)
      return out""") or []
    return [strip_codes(x) for x in lines]


def open_home(w, cl):
    cl.slash("/dz home")
    w.tick(0.5)


def buttons_enabled(cl):
    return cl.eval_py("local out = {}; for i, b in ipairs(ns.Dashboard:GetPanel().raidCard.buttons) do "
                      "out[i] = b:IsShown() and b:IsEnabled() and true or false end; return out")


@case
def the_home_card_answers_like_the_raids_tab():
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Olaf", 1, "WARRIOR"), ("Lee", 3, "WARRIOR"),
                            ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"), ("Lalt", 4, "WARLOCK")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, level=70)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    # Lalt is Lee's alt (as if each had logged in on the other's account)
    for cl, other in ((c["Lee"], "Lalt"), (c["Lalt"], "Lee")):
        cl.eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
                "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; ns.db.accounts[gk].mine[...] = true",
                K(other))
    w.tick(50)                      # everyone's own account entry goes out 25-45 s after login
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Kara A", ["Lee", "Rita", "Sam", "Olaf"])
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    w.tick(2)
    # Lee answered with his alt; Sam was declined; Olaf is blacklisted
    res = lee.eval_py("local ok, e = ns.RaidPlan:SignUp(...); return { ok = ok, e = e }", occ, "A", 3, None, K("Lalt"))
    assert res["ok"] is True, res
    assert call(bob, "DeclineSignup", occ, K("Sam"))["ok"] is True
    assert call(bob, "SetBlacklisted", "Olaf", "x")["ok"] is True
    w.tick(3)
    open_home(w, lee)
    texts = home_texts(lee)
    assert any("Your answer: Accepted" in t for t in texts), texts
    assert any("1 invited, no response" in t for t in texts), texts          # Rita only
    assert all(buttons_enabled(lee))
    # Lee's click answers for the character his answer is for
    lee.click(lee.eval("return ns.Dashboard:GetPanel().raidCard.buttons[2]"))
    w.tick(1)
    assert signups(rita, occ)[K("Lalt")]["st"] == "T" and K("Lee") not in signups(rita, occ)
    for cl, why in ((sam, "taken off this raid"), (c["Olaf"], "can't sign up")):
        open_home(w, cl)
        texts = home_texts(cl)
        assert any(("Your answer: " + why) in t for t in texts), (cl.name, texts)
        assert buttons_enabled(cl) == [False] * 4, cl.name
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
