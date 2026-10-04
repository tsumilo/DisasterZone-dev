"""Guest book 1.3: pugs in our raids, remembered for the organizers and for recruiting.

Covers: a player outside the guild who joins a raid group that is a planned raid becoming its guest (no raid session
needed; one writer: the raid leader, else the first assistant by name who may; a guest taken off by hand is not added
again; no planned raid, no guest); a blacklisted player who joins (the leader's popup removes them, other organizers get
a line, nobody adds them) and inviting one (a warning at once); the notes and Recruit marks (organizers only, shared,
reaching an organizer who was offline, checked input); the history from the raid log (raids, a join line with it the
next time); the player tooltip (the blacklist for everyone when outside the guild, guild members and reasons only for
organizers; the guest line); the Guests window (the book, its filter and menu, the note popup, the Blacklist tab); the
Add players window's known players; the player right-click menus; guests left out of the Raid log's Players list.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_guestbook.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, create, signup, signups, call  # noqa: E402
from _common import case, run_all, strip_codes, install_helpers, tt_lines, printed_since, menu_texts  # noqa: E402

P = "ns.RaidsUI:GetPanel()"

# Gina = GM, Bob = guild council + raid leader, Olaf = an officer (rank 1) on no list, the others members; the pugs are
# outside any guild.
NAMES = (("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Olaf", 1, "WARRIOR"), ("Lee", 3, "WARRIOR"),
         ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))
PUGS = (("Pug", "WARLOCK"), ("Bad", "HUNTER"))


def world():
    w = World()
    w.auto_session = False
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for name, cls in PUGS:
        c[name] = Client(w, name, guild=None, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    w.tick(2)
    return w, c


def guests(cl, occ):
    return cl.eval_py("return ns.RaidPlan:GetGuests(...)", occ) or {}


def kara_now(w, c, signed=("Lee", "Rita", "Sam")):
    """A Karazhan raid starting in 10 minutes that three members accepted."""
    occ = create(c["Bob"], i="kara", t=now(c["Bob"]) + 600)
    w.tick(2)
    for n in signed:
        assert signup(c[n], occ, "A")["ok"] is True, n
    w.tick(2)
    return occ


def note(cl, key):
    return cl.eval_py("return ns.GuestBook:GetNote(...)", key)


def entry(cl, key):
    return cl.eval_py("local e = ns.GuestBook:GetEntry(...); if not e then return nil end; "
                      "return { raids = e.raids, kills = e.kills, c = e.c, sp = e.sp, recruit = e.recruit, "
                      "note = e.note, blacklisted = e.blacklisted, noShows = e.noShows }", key)


def unit_tooltip(cl, name):
    install_helpers(cl)
    cl.set_target(name)
    cl.eval("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); GameTooltip:SetUnit('target')")
    lines = [strip_codes(l) for l, _ in tt_lines(cl)]
    cl.eval("GameTooltip:Hide()")
    return lines


# ------------------------------------------------------------------------------------------------------------------
@case
def a_pug_who_joins_a_planned_raid_becomes_a_guest():
    w, c = world()
    bob, rita, pug = c["Bob"], c["Rita"], c["Pug"]
    occ = kara_now(w, c)
    p0 = len(bob.chat_frame)
    w.make_raid([bob, c["Lee"], rita, c["Sam"], pug], leader=bob)          # no raid session: not needed
    w.tick(6)
    g = guests(rita, occ)
    assert list(g) == [K("Pug")] and g[K("Pug")]["c"] == "WARLOCK", g
    said = printed_since(bob, p0)
    assert any("Added Pug (Warlock) as a guest of Karazhan" in l for l in said), said
    assert not any("Added" in l for l in printed_since(rita, 0))           # (only the leader writes)
    # an organizer takes the guest off by hand: they stay off, also after the next roster change
    assert call(bob, "RemoveGuest", occ, K("Pug"))["ok"] is True
    w.tick(2)
    w.make_raid([bob, c["Lee"], rita, c["Sam"], pug, c["Olaf"]], leader=bob)
    w.tick(6)
    assert guests(rita, occ) == {}
    w.assert_no_errors()


@case
def without_a_planned_raid_nobody_is_added_and_the_assistant_writes():
    w, c = world()
    bob, lee, olaf, pug = c["Bob"], c["Lee"], c["Olaf"], c["Pug"]
    # no planned raid at this time: nothing happens
    w.make_raid([bob, lee, c["Rita"], pug], leader=bob)
    w.tick(6)
    assert bob.eval("return #ns.RaidPlan:GetRaids()") == 0
    w.disband()
    w.tick(2)
    # the leader (Lee) may not add guests: the first assistant who may does it (Olaf)
    occ = kara_now(w, c)
    w.make_raid([lee, olaf, c["Rita"], c["Sam"], pug], leader=lee, assistants=[olaf])
    w.tick(6)
    assert list(guests(c["Rita"], occ)) == [K("Pug")]
    assert any("Added Pug" in l for l in printed_since(olaf, 0))
    w.assert_no_errors()


@case
def a_blacklisted_player_who_joins_or_is_invited():
    w, c = world()
    bob, olaf, rita, bad = c["Bob"], c["Olaf"], c["Rita"], c["Bad"]
    occ = kara_now(w, c)
    assert call(bob, "SetBlacklisted", "Bad", "ninja looted Gruul")["ok"] is True
    w.tick(3)
    # inviting them: a warning at once (the game's /invite, unit menus, other addons)
    p0 = len(bob.chat_frame)
    bob.eval("C_PartyInfo.InviteUnit('Bad')")
    said = printed_since(bob, p0)
    assert sum("Bad is on the raid blacklist" in l for l in said) == 1 and any("ninja looted Gruul" in l for l in said), said
    w.disband()
    w.tick(1)
    # they join anyway: the leader gets a popup, an organizer without lead a line, a member nothing
    p_olaf, p_rita = len(olaf.chat_frame), len(rita.chat_frame)
    w.make_raid([bob, olaf, c["Lee"], rita, c["Sam"], bad], leader=bob)
    w.tick(6)
    assert "DISASTERZONE_BLACKLIST_JOINED" in bob.popups(), bob.popups()
    assert any("Bad is on the raid blacklist" in l and "ninja" in l for l in printed_since(olaf, p_olaf))
    assert not any("blacklist" in l for l in printed_since(rita, p_rita))
    assert guests(rita, occ) == {}                                           # never added as a guest
    # Keep: after the leader's /reload no popup again, a chat line instead
    bob.cancel_popup("DISASTERZONE_BLACKLIST_JOINED")
    bob.relog()
    w.tick(12)
    assert "DISASTERZONE_BLACKLIST_JOINED" not in bob.popups(), bob.popups()
    assert any("Bad is on the raid blacklist" in l for l in printed_since(bob, 0))
    # the next time they join: Remove from group
    w.make_raid([bob, olaf, c["Lee"], rita, c["Sam"]], leader=bob)
    w.tick(3)
    w.make_raid([bob, olaf, c["Lee"], rita, c["Sam"], bad], leader=bob)
    w.tick(6)
    bob.accept_popup("DISASTERZONE_BLACKLIST_JOINED")                        # Remove from group
    w.tick(2)
    assert "Bad" not in {m.name for m in w.group_members()}
    w.assert_no_errors()


@case
def two_blacklisted_players_get_one_popup_each():
    w, c = world()
    bob = c["Bob"]
    for name in ("Bad", "Pug"):
        assert call(bob, "SetBlacklisted", name, "x")["ok"] is True
    w.tick(3)
    w.make_raid([bob, c["Lee"], c["Rita"], c["Bad"], c["Pug"]], leader=bob)
    w.tick(6)
    assert bob.popups().count("DISASTERZONE_BLACKLIST_JOINED") == 1, bob.popups()
    bob.cancel_popup("DISASTERZONE_BLACKLIST_JOINED")                        # Keep the first
    w.tick(1)
    assert "DISASTERZONE_BLACKLIST_JOINED" in bob.popups(), bob.popups()     # then the second
    bob.accept_popup("DISASTERZONE_BLACKLIST_JOINED")
    w.tick(2)
    assert len({m.name for m in w.group_members()} & {"Bad", "Pug"}) == 1
    w.assert_no_errors()


@case
def notes_and_recruit_marks_are_shared_between_the_organizers():
    w, c = world()
    bob, olaf, lee, rita, gina = c["Bob"], c["Olaf"], c["Lee"], c["Rita"], c["Gina"]
    gina.logout()
    w.tick(2)
    res = bob.eval_py("local ok, e = ns.GuestBook:SetNote('Pug', 'good healer, wants to join', true); "
                      "return { ok = ok, e = e }")
    assert res["ok"] is True, res
    w.tick(3)
    for x in (olaf, rita):
        n = note(x, K("Pug"))
        assert n and n["note"] == "good healer, wants to join" and n["recruit"] is True and n["by"] == K("Bob"), (x.name, n)
    # only the organizers write it; checked input
    assert lee.eval_py("local ok, e = ns.GuestBook:SetNote('Pug', 'x'); return { ok = ok }")["ok"] is False
    assert bob.eval_py("local ok, e = ns.GuestBook:SetNote('Rita', 'x'); return { ok = ok }")["ok"] is False   # a member
    assert bob.eval_py("local ok, e = ns.GuestBook:SetNote('Pug', ...); return { ok = ok }", "x" * 61)["ok"] is False
    assert bob.eval_py("local ok, e = ns.GuestBook:SetNote('Pug', 'a|b'); return { ok = ok }")["ok"] is False
    # an officer clears the note, the mark stays
    assert olaf.eval_py("local ok = ns.GuestBook:SetNote('Pug', false); return { ok = ok }")["ok"] is True
    w.tick(3)
    n = note(bob, K("Pug"))
    assert n.get("note") is None and n["recruit"] is True, n
    # the GM was offline: she gets the book when she logs in
    gina.login()
    w.tick(60)
    n = note(gina, K("Pug"))
    assert n and n["recruit"] is True and n.get("note") is None, n
    w.assert_no_errors()


@case
def the_book_remembers_raids_and_greets_a_known_pug():
    w, c = world()
    bob, rita, pug = c["Bob"], c["Rita"], c["Pug"]
    kara_now(w, c)
    w.enter_instance("Karazhan", 532)
    w.make_raid([bob, c["Lee"], rita, c["Sam"], pug], leader=bob)
    w.tick(6)
    assert bob.eval("return (ns.GroupRules:SetSession(true, nil, { loot = false, rolls = false, lock = false }))") is True
    w.tick(3)
    inside = [bob, c["Lee"], rita, c["Sam"], pug]
    w.encounter(652, "Attumen the Huntsman", clients=inside)
    w.tick(3)
    assert bob.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    e = entry(bob, K("Pug"))
    assert e and e["raids"] == 1 and e["kills"] == 1 and e["c"] == "WARLOCK", e
    assert entry(bob, K("Rita")) is None                                    # guild members are not guests
    assert bob.eval_py("local ok = ns.GuestBook:SetNote('Pug', 'solid healer', true); return { ok = ok }")["ok"] is True
    # the next raid: when they join, the organizers get a line with what the book knows
    w.make_raid([bob, c["Lee"], rita, c["Sam"]], leader=bob)
    w.tick(4)
    p0 = len(bob.chat_frame)
    w.make_raid([bob, c["Lee"], rita, c["Sam"], pug], leader=bob)
    w.tick(4)
    said = printed_since(bob, p0)
    line = [l for l in said if l.startswith("|cffff8000DisasterZone|r: Pug")]
    assert line and "joined: 1 raid with us (last " in line[0] and "Recruit" in line[0] and '"solid healer"' in line[0], said
    assert not any("joined" in l for l in printed_since(rita, 0))            # not an organizer
    w.assert_no_errors()


@case
def the_player_tooltip():
    w, c = world()
    bob, rita, olaf = c["Bob"], c["Rita"], c["Olaf"]
    assert call(bob, "SetBlacklisted", "Bad", "ninja looted Gruul")["ok"] is True
    assert call(bob, "SetBlacklisted", "Lee", "no-shows")["ok"] is True
    assert bob.eval_py("local ok = ns.GuestBook:SetNote('Pug', 'healer', true); return { ok = ok }")["ok"] is True
    w.tick(3)
    # a pug on the blacklist: everyone sees it, only the organizers why
    lines = unit_tooltip(rita, "Bad")
    assert "DisasterZone: on the raid blacklist" in lines and "ninja looted Gruul" not in lines, lines
    lines = unit_tooltip(bob, "Bad")
    assert "DisasterZone: on the raid blacklist" in lines and "ninja looted Gruul" in lines, lines
    assert any(l.startswith("Added by Bob") for l in lines), lines
    # a guild member on it: only the organizers
    assert not any("blacklist" in l for l in unit_tooltip(rita, "Lee"))
    assert "DisasterZone: on the raid blacklist" in unit_tooltip(olaf, "Lee")
    # what the guest book knows, for the organizers
    assert any(l.startswith("DisasterZone guest: Recruit") for l in unit_tooltip(bob, "Pug")), unit_tooltip(bob, "Pug")
    assert not any("DisasterZone" in l for l in unit_tooltip(rita, "Pug"))
    assert not any("DisasterZone" in l for l in unit_tooltip(bob, "Sam"))
    w.assert_no_errors()


@case
def the_guests_window():
    w, c = world()
    bob, rita, pug, lee = c["Bob"], c["Rita"], c["Pug"], c["Lee"]
    occ = kara_now(w, c)
    w.make_raid([bob, lee, rita, c["Sam"], pug], leader=bob)
    w.tick(6)
    later = create(bob, i="gruul", t=now(bob) + 3 * DAY)
    w.tick(2)
    bob.slash("/dz raids")
    w.tick(0.5)
    assert bob.eval("return %s.guestsBtn:IsShown()" % P) is True
    lee.slash("/dz raids")
    w.tick(0.5)
    assert lee.eval("return %s.guestsBtn:IsShown()" % P) is False
    assert lee.eval("return ns.GuestBookUI:Open()") is False
    bob.click(bob.eval("return %s.guestsBtn" % P))
    w.tick(0.5)
    B = "ns.GuestBookUI:GetBookPage()"
    assert bob.eval("return %s:IsVisible()" % B) is True
    rows = bob.eval_py("local o = {}; for _, e in ipairs(%s.list:GetData()) do o[#o + 1] = e.key end; return o" % B)
    assert rows == [K("Pug")], rows
    # the row's Status column: their next guest seat (the raid's name is in the tooltip)
    seat = bob.eval("return date('%a %d %b', ns.GuestBook:GetEntry(...).next.t)", K("Pug"))
    assert bob.find_text("Guest " + seat, True, True)
    # the row's menu: recruit, a note, add to a raid
    bob.eval("ns.GuestBookUI:OpenEntryMenu(UIParent, ns.GuestBook:GetEntry(...))", K("Pug"))
    texts = [strip_codes(t[2] or "") for t in menu_texts(bob.last_menu())]
    for t in ("Add as a guest to", "Mark as recruit", "Add a note...", "Blacklist...", "Whisper"):
        assert any(t in x for x in texts), (t, texts)
    bob.menu_select("Mark as recruit")
    w.tick(1)
    assert note(rita, K("Pug"))["recruit"] is True
    bob.eval("ns.GuestBookUI:EditNote('Pug')")
    bob.accept_popup("DISASTERZONE_GUEST_NOTE", "plays every reset")
    w.tick(1)
    assert note(rita, K("Pug"))["note"] == "plays every reset"
    assert bob.eval("return ns.GuestBookUI:AddToRaid(...)", K("Pug"), later) is True
    w.tick(2)
    assert guests(rita, later)[K("Pug")]["c"] == "WARLOCK"
    # the filter: recruits only, and a name
    bob.click(bob.eval("return %s.recruits" % B))
    w.tick(0.5)
    assert len(bob.eval_py("return %s.list:GetData()" % B) or []) == 1
    bob.type_text(bob.eval("return %s.search" % B), "zzz")
    w.tick(0.5)
    assert len(bob.eval_py("return %s.list:GetData()" % B) or []) == 0
    # a player who has not raided with us: a note adds them to the book
    bob.eval("ns.GuestBookUI:EditNote('Newbie')")
    bob.accept_popup("DISASTERZONE_GUEST_NOTE", "met in trade chat")
    w.tick(1)
    assert entry(bob, K("Newbie"))["note"] == "met in trade chat"
    # the Blacklist tab
    bob.click(bob.eval("return ns.GuestBookUI:GetWindow().blackTab"))
    w.tick(0.3)
    assert bob.eval("return ns.RaidPlanUI:GetBlacklistWindow():IsVisible()") is True
    assert bob.eval("return %s:IsVisible()" % B) is False
    assert occ
    w.assert_no_errors()


@case
def known_players_in_the_add_players_window():
    w, c = world()
    bob, pug, rita = c["Bob"], c["Pug"], c["Rita"]
    later = create(bob, i="gruul", t=now(bob) + 3 * DAY)
    w.tick(2)
    w.make_party([bob, pug], leader=bob)
    w.tick(3)
    bob.slash("/dz raids")
    w.tick(0.5)
    assert bob.eval("return ns.RaidPlanUI:OpenInvites(...)", later) is True
    G = "ns.RaidPlanUI:GetInviteWindow()"
    bob.click(bob.eval("return %s.guestTab" % G))
    menu = bob.dropdown_menu(bob.eval("return %s.knownBtn" % G))
    texts = [strip_codes(t[2] or "") for t in menu_texts(menu)]
    assert "In your group" in texts and any(t.startswith("Pug") and "Warlock" in t for t in texts), texts
    picked = [t[2] for t in menu_texts(menu) if strip_codes(t[2] or "").startswith("Pug")][0]
    bob.menu_select(picked)
    w.tick(2)
    assert guests(rita, later)[K("Pug")]["c"] == "WARLOCK"
    # a name the book knows fills in the class
    assert bob.eval_py("local ok = ns.GuestBook:SetNote('Healz', 'x'); return { ok = ok }")["ok"] is True
    bob.eval("local s = ns.GuestBook; local t = ns.db.guestSpecs[ns.Guild:GetGuildKey()] or {}; "
             "ns.db.guestSpecs[ns.Guild:GetGuildKey()] = t; t[...] = { c = 'PRIEST', sp = 2, at = GetServerTime() }",
             K("Healz"))
    bob.eval("ns:Fire('ROSTER_UPDATED')")                     # (the book is rebuilt after a change of its sources)
    bob.type_text(bob.eval("return %s.nameBox" % G), "Healz")
    w.tick(0.3)
    assert bob.eval("return %s.cls" % G) == "PRIEST" and bob.eval("return %s.sp" % G) == 2
    w.assert_no_errors()


@case
def the_player_right_click_menus():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    assert bob.eval("return __MOCK.menu_modifiers ~= nil and __MOCK.menu_modifiers.MENU_UNIT_PLAYER ~= nil") is True

    def menu(cl, ctx):
        return [strip_codes(t[2] or "") for t in menu_texts(cl.eval_py(
            "local ctx = ...; local root = MenuUtil.CreateRootMenuDescription(); "
            "__MOCK.menu_modifiers.MENU_UNIT_PLAYER(UIParent, root, ctx); "
            "local o = { children = {} }; for i, d in ipairs(root.children) do "
            "o.children[i] = { text = d.text, kind = d.kind, children = {} } end; return o", ctx))]
    bob.set_target("Pug")
    texts = menu(bob, {"unit": "target"})
    assert "Blacklist..." in texts and "Guest book..." in texts, texts
    texts = menu(bob, {"name": "Sam", "server": ""})                         # a chat name; a guild member
    assert "Blacklist..." in texts and "Guest book..." not in texts, texts
    rita.set_target("Pug")
    assert menu(rita, {"unit": "target"}) == []                               # members: nothing
    w.assert_no_errors()


@case
def guests_are_left_out_of_the_players_list():
    w, c = world()
    bob, pug = c["Bob"], c["Pug"]
    w.make_raid([bob, c["Lee"], c["Rita"], pug], leader=bob)
    w.tick(4)
    assert bob.eval("return (ns.GroupRules:SetSession(true, nil, { loot = false, rolls = false, lock = false }))") is True
    w.tick(3)
    assert bob.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetMode('players')")
    w.tick(0.5)

    def names():
        rows = bob.eval_py("return %s.players:GetData()" % P) or []
        return [strip_codes(r["cols"][0]) for r in rows[1:]]
    assert "Pug (guest)" not in names() and "Bob" in names(), names()
    bob.click(bob.eval("return %s.guestsToggle" % P))
    w.tick(0.5)
    assert "Pug (guest)" in names(), names()
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
