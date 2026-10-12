"""Guild professions (Core/Professions.lua) and the Members tab (UI/Members.lua), on the real addon.

A client reads only its own character's professions (skill list) and, while a profession window is open, its recipes;
every client shares them on the guild channel (prefix CDLm) and keeps what the others shared.

Covers: own professions and specialisation read and shared; recipes from the trade skill window and the craft window
(Enchanting), not from a linked profession or Beast Training; a filtered window only adds; a member who logs in later
gets everything, also of members who are offline (passed on by others); a dropped profession takes its recipes along;
a relog keeps the data; a forged record of me loses; malformed messages; a large recipe list (several parts); members
who left the guild are forgotten; the packed text form; the Members tab (roster, filter, recipes, search, whisper,
link) and the "made by" tooltip line.

Run: luaenv\\Scripts\\python.exe tests\\members\\test_professions.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from mb_common import (World, Client, case, run_all, K, set_skills, open_tradeskill, open_craft, member,  # noqa: E402
                       crafters, guild, join, teach_names, ALCHEMY, TAILORING, ENCHANTING)
from _common import printed_since  # noqa: E402

ALCH, TAIL, ENCH, COOK, HERB = 171, 197, 333, 185, 182
SYNC = 200   # seconds: the login index (45-90 s), the answers and the recipe requests


def trio():
    w, c = guild([("Gina", "PALADIN"), ("Alfa", "MAGE"), ("Bert", "ROGUE")])
    return w, c["Gina"], c["Alfa"], c["Bert"]


def member_traffic(w, start=0):
    return [e for e in w.addon_log[start:] if e["prefix"] == "CDLm"]


# ------------------------------------------------------------------------------------------------------------------
@case
def own_professions_are_read_and_shared():
    w, g, a, b = trio()
    a.eval("__MOCK.known_spells[28675] = true")   # Potion Master
    set_skills(a, [("Alchemy", 362, 375), ("Herbalism", 375, 375), ("Cooking", 120, 150)])
    w.tick(SYNC)
    for cl in (a, b, g):
        m = member(cl, "Alfa")
        assert m is not None and set(m) == {ALCH, HERB, COOK}, (cl.name, m)
        assert (m[ALCH]["rank"], m[ALCH]["max"], m[ALCH].get("spec")) == (362, 375, 28675), m[ALCH]
        assert (m[HERB]["rank"], m[COOK]["max"]) == (375, 150)
    assert b.eval_py("return ns.Professions:GetCounts()") == {ALCH: 1, HERB: 1, COOK: 1}
    # a skill-up reaches the others
    set_skills(a, [("Alchemy", 370, 375), ("Herbalism", 375, 375), ("Cooking", 120, 150)])
    w.tick(SYNC)
    assert member(b, "Alfa")[ALCH]["rank"] == 370
    # a member without professions is known too (as having none)
    assert member(a, "Bert") == {}
    w.assert_no_errors()


@case
def a_collapsed_skill_header_does_not_drop_professions():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 300, 375)])
    w.tick(5)
    assert set(member(a, "Alfa")) == {ALCH}
    set_skills(a, [("Alchemy", 300, 375)], collapsed=True)
    w.tick(5)
    assert set(member(a, "Alfa")) == {ALCH}
    w.assert_no_errors()


@case
def recipes_come_from_the_profession_windows():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375), ("Enchanting", 375, 375)])
    w.tick(5)
    assert a.eval_py("return ns.Professions:GetUnscanned()") == [ALCH, ENCH]
    open_tradeskill(a, "Alchemy", ALCHEMY)
    open_craft(a, "Enchanting", ENCHANTING)
    w.tick(2)
    assert not a.eval_py("return ns.Professions:GetUnscanned()")
    m = member(a, "Alfa")
    assert (m[ALCH]["recipes"], m[ENCH]["recipes"]) == (5, 3), m
    w.tick(SYNC)
    for cl in (b, g):
        m = member(cl, "Alfa")
        assert (m[ALCH]["recipes"], m[ALCH]["total"], m[ALCH]["synced"]) == (5, 5, True), (cl.name, m)
        assert m[ENCH]["recipes"] == 3
        r = cl.eval_py("return ns.Professions:GetRecipe(28587)")
        assert (r["item"], r["prof"], r["crafters"]) == (22851, ALCH, [K("Alfa")]), r
        r = cl.eval_py("return ns.Professions:GetRecipe(27984)")
        assert (r["item"], r["prof"]) == (0, ENCH), r
        assert [x["spell"] for x in cl.eval_py("return ns.Professions:GetRecipesForItem(22851)")] == [28587]
        assert len(cl.eval_py("return ns.Professions:GetMemberRecipes(..., 171)", K("Alfa"))) == 5
    w.assert_no_errors()


@case
def a_linked_profession_and_beast_training_are_not_mine():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375), ("Enchanting", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY, linked="Somebody")
    open_craft(a, "Beast Training", [("Bite", 17253, None)], noline=True)
    w.tick(2)
    open_craft(a, "Tailoring", TAILORING)     # a profession I don't have
    w.tick(2)
    m = member(a, "Alfa")
    assert (m[ALCH]["recipes"], m[ENCH]["recipes"]) == (0, 0) and set(m) == {ALCH, ENCH}, m
    w.assert_no_errors()


@case
def a_filtered_window_only_adds_recipes():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    w.tick(2)
    open_tradeskill(a, "Alchemy", ALCHEMY[:2])      # a search filter in the window
    a.fire("TRADE_SKILL_UPDATE")
    w.tick(2)
    assert member(a, "Alfa")[ALCH]["recipes"] == 5
    open_tradeskill(a, "Alchemy", ALCHEMY + [("Elixir of Major Defense", 28557, 22834)])   # learned a new one
    w.tick(2)
    assert member(a, "Alfa")[ALCH]["recipes"] == 6
    w.tick(SYNC)
    assert member(b, "Alfa")[ALCH]["recipes"] == 6
    assert crafters(b, 28557) == [K("Alfa")]
    w.assert_no_errors()


@case
def a_late_login_gets_everything_also_of_offline_members():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    set_skills(b, [("Tailoring", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    open_tradeskill(b, "Tailoring", TAILORING)
    w.tick(SYNC)
    assert member(g, "Alfa")[ALCH]["recipes"] == 5 and member(g, "Bert")[TAIL]["recipes"] == 3
    a.logout()                                 # the alchemist is offline when Cleo installs DisasterZone
    w.tick(5)
    cleo = join(w, "Cleo")
    w.tick(SYNC + 120)
    m = member(cleo, "Alfa")
    assert m is not None and (m[ALCH]["rank"], m[ALCH]["recipes"], m[ALCH]["synced"]) == (375, 5, True), m
    assert member(cleo, "Bert")[TAIL]["recipes"] == 3
    assert crafters(cleo, 28587) == [K("Alfa")] and crafters(cleo, 31456) == [K("Bert")]
    # nothing is asked for twice once everything is there
    start = len(w.addon_log)
    w.tick(300)
    assert member_traffic(w, start) == [], member_traffic(w, start)[:3]
    w.assert_no_errors()


@case
def a_dropped_profession_takes_its_recipes_along():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375), ("Tailoring", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    w.tick(2)
    open_tradeskill(a, "Tailoring", TAILORING)
    w.tick(SYNC)
    assert crafters(b, 28587) == [K("Alfa")] and crafters(b, 31456) == [K("Alfa")]
    set_skills(a, [("Tailoring", 375, 375)])
    w.tick(SYNC)
    for cl in (a, b, g):
        assert set(member(cl, "Alfa")) == {TAIL}, cl.name
        assert crafters(cl, 28587) == [] and crafters(cl, 31456) == [K("Alfa")], cl.name
    # relearned: a new start, the old recipes don't come back from somebody's copy
    set_skills(a, [("Tailoring", 375, 375), ("Alchemy", 1, 75)])
    w.tick(SYNC)
    for cl in (a, b, g):
        m = member(cl, "Alfa")
        assert (m[ALCH]["rank"], m[ALCH]["recipes"]) == (1, 0), (cl.name, m)
    w.assert_no_errors()


@case
def a_relog_keeps_the_data():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    w.tick(SYNC)
    b.relog()
    w.tick(3)
    m = member(b, "Alfa")
    assert m is not None and m[ALCH]["recipes"] == 5, m
    assert crafters(b, 29688) == [K("Alfa")]
    a.relog()
    w.tick(1)
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(5)
    assert member(a, "Alfa")[ALCH]["recipes"] == 5      # my own recipes survive without reopening the window
    w.assert_no_errors()


@case
def my_own_record_wins_over_a_forged_one():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(SYNC)
    b.eval("""ns.Comm:Send({ t = "PFB", l = { { k = ..., v = GetServerTime() + 30,
        p = { { 197, 1, 75, 0, GetServerTime(), 0, 0 } } } } }, "GUILD", nil, "member")""", K("Alfa"))
    w.tick(SYNC)
    for cl in (a, g):
        assert set(member(cl, "Alfa")) == {ALCH}, (cl.name, member(cl, "Alfa"))
    w.assert_no_errors()


@case
def malformed_messages_are_ignored():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(SYNC)
    alfa, gina = K("Alfa"), K("Gina")
    bad = [
        '{ t = "PFB" }', '{ t = "PFB", l = 5 }', '{ t = "PFB", l = { 5, "x", {} } }',
        '{ t = "PFB", l = { { k = "%s", v = "new", p = {} } } }' % gina,
        '{ t = "PFB", l = { { k = "%s", v = GetServerTime() + 99999, p = {} } } }' % gina,
        '{ t = "PFB", l = { { k = "%s", v = GetServerTime(), p = { { 9999, 1, 1, 0, 1, 0, 0 } } } } }' % gina,
        '{ t = "PFB", l = { { k = "%s", v = GetServerTime(), p = { { 171, -5, 1, 0, 1, 0, 0 } } } } }' % gina,
        '{ t = "PFB", l = { { k = "%s", v = GetServerTime(), p = { { 171, 1, 1, 26797, 1, 0, 0 } } } } }' % gina,
        '{ t = "PFB", l = { { k = "Stranger-Thunderstrike", v = GetServerTime(), p = {} } } }',
        '{ t = "PFR" }', '{ t = "PFR", k = "%s", i = 171, e = 1, rr = 1, d = 5 }' % gina,
        '{ t = "PFR", k = "%s", i = 171, e = 1, rr = 1, d = "!!!" }' % gina,
        '{ t = "PFR", k = "%s", i = 171, e = 1, rr = 1, d = "1" }' % gina,
        '{ t = "PFR", k = "%s", i = 4, e = 1, rr = 1, d = "11" }' % gina,
        '{ t = "PFI" }', '{ t = "PFI", i = { 1, 2, 3 }, a = 5 }', '{ t = "PFI", i = { [5] = "x", x = {} } }',
    ]
    for src in bad:
        b.eval('ns.Comm:Send(%s, "GUILD", nil, "member")' % src)
    for src in ('{ t = "PFW" }', '{ t = "PFW", s = 5, r = "x" }',
                '{ t = "PFW", s = { 1, {} }, r = { 1, { 1 }, { "%s", "x" } } }' % alfa):
        b.eval('ns.Comm:Send(%s, "WHISPER", ..., "member")' % src, alfa)
    w.tick(30)
    assert member(a, "Gina") == {}, member(a, "Gina")
    assert member(a, "Stranger") is None
    assert set(member(g, "Alfa")) == {ALCH}
    w.assert_no_errors()


@case
def a_large_recipe_list_travels_in_parts():
    w, g, a, b = trio()
    set_skills(a, [("Tailoring", 375, 375)])
    w.tick(5)
    big = [("Recipe %d" % i, 40000 + 3 * i, 20000 + 7 * i if i % 4 else None) for i in range(620)]
    open_tradeskill(a, "Tailoring", big)
    w.tick(SYNC)
    for cl in (a, b, g):
        m = member(cl, "Alfa")
        assert (m[TAIL]["recipes"], m[TAIL]["total"], m[TAIL]["synced"]) == (620, 620, True), (cl.name, m)
    assert b.eval("local r = ns.Professions:GetRecipe(40003); return r.item") == 20007
    assert b.eval("local r = ns.Professions:GetRecipe(40000); return r.item") == 0
    # a later login asks for it and gets every part
    cleo = join(w, "Cleo")
    w.tick(SYNC + 120)
    assert member(cleo, "Alfa")[TAIL]["recipes"] == 620
    w.assert_no_errors()


@case
def members_who_left_the_guild_are_forgotten():
    w, g, a, b = trio()
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(SYNC)
    assert member(b, "Alfa") is not None
    # a record of somebody who is not on the roster (left while I was offline)
    b.eval("""local gk = ns.Guild:GetGuildKey()
        DisasterZoneDB.prof[gk]["Gone-Thunderstrike"] = { rev = 5, p = { [171] = { r = 1, m = 75, e = 1, rr = 0, n = 0 } }, R = {} }""")
    w.add_offline_member("Newbie", "DRUID", 3)
    for cl in (a, b, g):
        cl.eval("C_GuildInfo.GuildRoster()")
    w.tick(5)
    assert b.eval('return DisasterZoneDB.prof[ns.Guild:GetGuildKey()]["Gone-Thunderstrike"]') is None
    assert member(b, "Alfa") is not None
    w.assert_no_errors()


@case
def the_packed_form_round_trips():
    w = World()
    a = Client(w, "Alfa")
    a.load_addon()
    res = a.eval_py("""
      local P = ns.Professions
      local map = { [5] = 0, [6] = 40000, [100] = 7, [33000] = 16777215, [16777215] = 1, [16777214] = 0, [70] = 39999 }
      local text = P._Pack(map)
      local back, n = {}, nil
      n = P._Unpack(text, function(spell, item) back[#back + 1] = { spell, item } end)
      local same = n == 7
      for _, pair in ipairs(back) do if map[pair[1]] ~= pair[2] then same = false end end
      return { same = same, printable = not text:find("[^%w%-_]"), empty = P._Unpack("", nil),
               bad1 = P._Unpack("1", nil) == nil, bad2 = P._Unpack("0101", nil) == nil, bad3 = P._Unpack("1 1", nil) == nil,
               bad4 = P._Unpack(("z"):rep(40), nil) == nil, bad5 = P._Unpack(5, nil) == nil }""")
    assert res == {"same": True, "printable": True, "empty": 0, "bad1": True, "bad2": True, "bad3": True, "bad4": True,
                   "bad5": True}, res
    w.assert_no_errors()


@case
def a_guildless_character_only_sees_itself():
    w = World()
    a = Client(w, "Alfa", guild=None)
    a.load_addon()
    teach_names(a)
    w.tick(3)
    set_skills(a, [("Alchemy", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    w.tick(SYNC)
    assert member(a, "Alfa")[ALCH]["recipes"] == 5
    assert member_traffic(w) == []
    a.slash("/dz members")
    w.tick(1)
    assert a.find_text("Alfa")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The Members tab
# ------------------------------------------------------------------------------------------------------------------
def ui_world():
    w, g, a, b = trio()
    w.add_offline_member("Zed", "WARRIOR", 3)
    a.eval("__MOCK.known_spells[28675] = true")
    set_skills(a, [("Alchemy", 375, 375), ("Enchanting", 300, 375), ("Cooking", 100, 150)])
    set_skills(g, [("Alchemy", 320, 375), ("Tailoring", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    open_craft(a, "Enchanting", ENCHANTING)
    open_tradeskill(g, "Alchemy", ALCHEMY[:2])
    w.tick(2)
    open_tradeskill(g, "Tailoring", TAILORING)
    w.tick(SYNC)
    b.slash("/dz members")
    w.tick(1)
    return w, g, a, b


def roster(cl):
    return cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.MembersUI:GetPanel().roster:GetData()) do
        out[#out + 1] = d.kind == "sep" and "--" or ns.Util.ShortName(d.key)
      end
      return out""") or []


def recipes_listed(cl):
    return cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.MembersUI:GetPanel().recipes:GetData()) do out[#out + 1] = d.r.name end
      return out""") or []


def detail(cl):
    return cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.MembersUI:GetPanel().right.list:GetData()) do
        out[#out + 1] = { kind = d.kind, key = d.key, id = d.id, text = d.text, name = d.r and d.r.name,
                          whisper = d.canWhisper }
      end
      return out""") or []


@case
def the_roster_lists_everyone_with_their_professions():
    w, g, a, b = ui_world()
    assert b.eval("return ns.MainFrame:GetSelectedTab()") == "members"
    # members with data first (online, by name; Bert has none), then the rest
    assert roster(b) == ["Alfa", "Bert", "Gina", "--", "Zed"], roster(b)
    assert b.eval("return ns.MembersUI:GetState().member") == K("Bert")      # me, on a first look
    assert b.find_text("All professions")                     # the filter (no member / recipe counts)
    b.eval("ns.MembersUI:SelectMember(...)", K("Alfa"))
    d = detail(b)
    assert [(x["kind"], x.get("id")) for x in d] == [("prof", 171), ("prof", 333), ("prof", 185)], d   # the Professions card
    assert b.find_text("Potion Master") and b.find_text("375 / 375") and b.find_text("5 recipes")
    # a profession opens into its recipes, grouped
    b.eval("ns.MembersUI:GetState().open[171] = true; ns.MembersUI:Refresh()")
    d = detail(b)
    assert sorted(x["name"] for x in d if x["kind"] == "recipe") == sorted(n for n, _, _ in ALCHEMY), d
    assert any(x["kind"] == "group" for x in d)
    # a member without data
    b.eval("ns.MembersUI:SelectMember(...)", K("Zed"))
    d = detail(b)
    assert len(d) == 1 and d[0]["kind"] == "note" and "not shared anything" in d[0]["text"], d
    w.assert_no_errors()


@case
def a_profession_icon_filters_and_sorts_by_skill():
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:SetProfession(171)")
    assert roster(b) == ["Alfa", "Gina"], roster(b)          # 375 before 320; nobody without the profession
    assert b.find_text("Alchemy")                             # the filter names it
    b.eval("ns.MembersUI:SetProfession(197)")
    assert roster(b) == ["Gina"]
    b.eval("ns.MembersUI:SetProfession(nil)")
    assert len(roster(b)) == 5
    # the search box filters names
    b.type_text(b.eval("return ns.MembersUI:GetPanel().search"), "al")
    w.tick(0.5)
    assert roster(b) == ["Alfa"], roster(b)
    w.assert_no_errors()


@case
def recipes_can_be_searched_and_show_their_crafters():
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:SetMode('recipes')")
    assert len(recipes_listed(b)) == 11
    b.type_text(b.eval("return ns.MembersUI:GetPanel().search"), "flask")
    w.tick(0.5)
    assert recipes_listed(b) == ["Flask of Fortification", "Flask of Mighty Restoration"], recipes_listed(b)
    b.eval("ns.MembersUI:SelectRecipe(28587)")
    d = detail(b)
    assert d[0]["kind"] == "head" and d[0]["text"] == "Crafters", d
    who = [(x["key"], x["whisper"]) for x in d if x["kind"] == "crafter"]
    assert who == [(K("Alfa"), True), (K("Gina"), True)], who                 # by skill: 375, 320
    assert b.find_text("Flask of Fortification") and b.find_text("Link in chat")
    # the profession filter narrows the list
    b.type_text(b.eval("return ns.MembersUI:GetPanel().search"), "")
    w.tick(0.5)
    b.eval("ns.MembersUI:SetProfession(333)")
    assert recipes_listed(b) == sorted(n for n, _, _ in ENCHANTING), recipes_listed(b)
    # an offline crafter can't be whispered
    a.logout()
    w.tick(3)
    b.eval("ns.MembersUI:SetProfession(nil); ns.MembersUI:SelectRecipe(29688)")
    d = detail(b)
    assert [(x["key"], x["whisper"]) for x in d if x["kind"] == "crafter"] == [(K("Alfa"), False)], d
    assert any(x["kind"] == "note" and "online" in x["text"] for x in d)
    w.assert_no_errors()


@case
def whisper_and_link_use_the_recipe_link():
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:ShowRecipe(27984)")
    assert b.eval("return ns.MembersUI:GetMode()") == "recipes"
    assert b.eval("return ns.MembersUI:GetState().prof") == 333
    link = b.eval("return GetSpellLink(27984)")          # an enchant: the client's own spell link
    # the Whisper button of the crafter row
    b.eval("""
      local list = ns.MembersUI:GetPanel().right.list
      list.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.kind == "crafter" then row.w.whisper:Click() end
      end)""")
    assert b.eval("return __MOCK.opened_chat") == "/w Alfa " + link + " ", b.eval("return __MOCK.opened_chat")
    # a recipe that makes an item is linked as that item
    b.eval("ns.MembersUI:ShowRecipe(28587)")
    b.eval("ns.MembersUI:GetPanel().right.link:Click()")
    sent = (b.inserted_links[-1:] or [None])[0] or b.eval("return __MOCK.opened_chat")
    assert "item:22851" in sent, sent
    # clicking a crafter jumps to them with that profession open
    b.eval("ns.MembersUI:ShowMember(..., 333)", K("Alfa"))
    assert b.eval("return ns.MembersUI:GetMode()") == "roster"
    d = detail(b)
    assert any(x["kind"] == "recipe" and x["name"] == "Enchant Weapon - Mongoose" for x in d), d
    w.assert_no_errors()


@case
def my_own_unread_professions_get_a_hint():
    w, g, a, b = trio()
    set_skills(b, [("Tailoring", 375, 375), ("Herbalism", 300, 375)])
    w.tick(5)
    b.slash("/dz members")
    w.tick(1)
    d = detail(b)
    assert d[-1]["kind"] == "note" and "Open your Tailoring window" in d[-1]["text"], d
    assert not b.find_text("recipes not shared yet")          # (the line under them says it, once)
    open_tradeskill(b, "Tailoring", TAILORING)
    w.tick(2)
    d = detail(b)
    assert not any("Open your" in (x.get("text") or "") for x in d), d
    assert b.find_text("3 recipes")
    start = len(b.chat_frame)
    b.slash("/dz professions")
    assert any("3 recipes known" in str(line) for line in b.chat_frame[start:]), b.chat_frame[start:]
    w.assert_no_errors()


@case
def item_tooltips_name_the_crafters():
    w, g, a, b = ui_world()
    lines = [left for left, _ in b.show_tooltip_item(22851)]
    made = [x for x in lines if x and "seal_mm:" in x and "Made by" in x]
    assert len(made) == 1 and "Alfa" in made[0] and "Gina" in made[0], lines
    lines = [left for left, _ in b.show_tooltip_item(28822)]       # nobody makes this
    assert not [x for x in lines if x and "Made by" in x], lines
    # hovering a recipe in the tab: the item, then who makes it (once)
    b.eval("ns.MembersUI:SetMode('recipes')")
    b.eval("""
      ns.MembersUI:GetPanel().recipes.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.r.spell == 28587 then row:GetScript("OnEnter")(row) end
      end)""")
    text = b.eval_py("""
      local out = {}
      for i = 1, GameTooltip:NumLines() do out[#out + 1] = _G["GameTooltipTextLeft" .. i]:GetText() or "" end
      return out""")
    assert any("Made by 2 in the guild" in x for x in text) and not any("seal_mm:" in x for x in text), text
    w.assert_no_errors()


@case
def the_made_by_header_of_a_recipe_tooltip_does_not_wrap():
    # (1.4 regression: a colour helper's 4th value, the alpha, landed in AddLine's wrap slot)
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:SetMode('recipes')")
    b.eval("""
      T_adds = {}
      local orig = GameTooltip.AddLine
      GameTooltip.AddLine = function(self, text, r, g, bl, wrap)
        T_adds[#T_adds + 1] = { tostring(text), wrap and true or false }
        return orig(self, text, r, g, bl, wrap)
      end
      ns.MembersUI:GetPanel().recipes.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.r.spell == 28587 then row:GetScript("OnEnter")(row) end
      end)
      GameTooltip.AddLine = orig""")
    adds = b.eval_py("return T_adds")
    made = [x for x in adds if "Made by" in x[0]]
    assert len(made) == 1 and made[0][1] is False, adds
    w.assert_no_errors()


@case
def a_recipe_shows_its_materials_with_shift_and_the_wheel_sets_the_amount():
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:SetMode('recipes')")
    b.eval("""
      T_row = nil
      ns.MembersUI:GetPanel().recipes.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.r.spell == 28587 then T_row = row end
      end)
      T_row:GetScript("OnEnter")(T_row)""")

    def left_lines():
        return b.eval_py("""
          local out = {}
          for i = 1, GameTooltip:NumLines() do
            out[#out + 1] = (_G["GameTooltipTextLeft" .. i]:GetText() or ""):gsub("|T[^|]*|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
          end
          return out""")
    side = "return DisasterZoneRecipeTooltip and DisasterZoneRecipeTooltip:IsShown() or false"
    text = left_lines()
    assert text[-1] == "Hold Shift: materials" and b.eval(side), text
    b.set_modifiers(shift=True)
    text = left_lines()
    # Flask of Fortification's first reagent, by the data
    first =b.eval_py("return ns.Atlas:GetCraft(-28587).reagents[1]")
    name = b.eval("return ns.Atlas:GetShippedName(...)", first["id"])
    assert "Materials" in text and any(name in x for x in text) and text[-1] == "Mouse wheel: change the amount", text
    assert not b.eval(side), "the recipe's own tooltip at the side duplicates the materials"
    b.eval("T_row:GetScript('OnMouseWheel')(T_row, 1)")
    assert "Materials ×2" in left_lines(), left_lines()
    b.set_modifiers(shift=False)
    assert left_lines()[-1] == "Hold Shift: materials" and b.eval(side), left_lines()
    w.assert_no_errors()


@case
def shift_click_on_a_recipe_breaks_its_materials_down_instead_of_linking():
    w, g, a, b = ui_world()
    b.eval("ns.MembersUI:SetMode('recipes')")
    b.eval("""
      T_row = nil
      ns.MembersUI:GetPanel().recipes.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.r.spell == 26746 then T_row = row end     -- Netherweave Bag: 4 Bolt of Netherweave, 1 Rune Thread
      end)
      T_row:GetScript("OnEnter")(T_row)
      T_links = 0
      local orig = ChatEdit_InsertLink
      ChatEdit_InsertLink = function(...) T_links = T_links + 1 return orig and orig(...) end
      if ChatFrameUtil then
        local o2 = ChatFrameUtil.InsertLink
        ChatFrameUtil.InsertLink = function(...) T_links = T_links + 1 return o2 and o2(...) end
      end""")

    def text():
        return " | ".join(b.eval_py("""
          local out = {}
          for i = 1, GameTooltip:NumLines() do
            out[#out + 1] = (_G["GameTooltipTextLeft" .. i]:GetText() or ""):gsub("|T[^|]*|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
          end
          return out"""))
    before = b.eval("return ns.MembersUI:GetState().recipe")
    b.set_modifiers(shift=True)
    assert "Bolt of Netherweave" in text() and "Click: break down" in text(), text()
    b.click(b.eval("return T_row"))
    assert "Materials · broken down once" in text() and "Netherweave Cloth" in text() \
        and "Bolt of Netherweave" not in text(), text()
    assert b.eval("return T_links") == 0, "a Shift + click over the materials must not link the recipe"
    b.click(b.eval("return T_row"), "RightButton")
    assert "broken down" not in text() and "Bolt of Netherweave" in text(), text()
    # a right-click without Shift does nothing here (the row only took right clicks for the materials)
    b.set_modifiers(shift=False)
    b.click(b.eval("return T_row"), "RightButton")
    assert b.eval("return ns.MembersUI:GetState().recipe") == before
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
