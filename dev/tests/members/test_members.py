"""The Members tab beyond professions: recipe names that load late, online state and level in the roster, main and off
spec (primary / secondary talents), alts under their main, the gear everyone wears (shared with the whole guild; the BiS
lists stay with the loot council), and the officer notes (Core/OfficerNotes.lua).

Run: luaenv\\Scripts\\python.exe tests\\members\\test_members.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from mb_common import (World, Client, case, run_all, K, set_skills, open_tradeskill, open_craft, member,  # noqa: E402
                       crafters, guild, join, teach_names, ALCHEMY, TAILORING, ENCHANTING)

SYNC = 200
P = "ns.Professions"
N = "ns.OfficerNotes"
UI = "ns.MembersUI"


def trio():
    w, c = guild([("Gina", "PALADIN"), ("Alfa", "MAGE"), ("Bert", "ROGUE")])
    return w, c["Gina"], c["Alfa"], c["Bert"]


def roster_rows(cl):
    return cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.MembersUI:GetPanel().roster:GetData()) do
        out[#out + 1] = d.kind == "sep" and { name = "--" }
          or { name = ns.Util.ShortName(d.key), status = d.status, level = d.level, alt = d.alt or false,
               specs = d.specs }
      end
      return out""") or []


def detail(cl):
    return cl.eval_py("""
      local out = {}
      for _, d in ipairs(ns.MembersUI:GetPanel().right.list:GetData()) do
        out[#out + 1] = { kind = d.kind, key = d.key, id = d.id, text = d.text, via = d.via, main = d.isMain,
                          whisper = d.canWhisper }
      end
      return out""") or []


def officer_msgs(w, start=0):
    return [e for e in w.addon_log[start:] if e["prefix"] == "CDLd" and e["chat_type"] == "WHISPER"]


# ------------------------------------------------------------------------------------------------------------------
@case
def recipes_whose_names_load_late_are_all_listed():
    """The client loads spell names on demand: the first look at a recipe may have no name yet. It must be listed
    anyway (the bug: most of a 133-recipe Enchanting list was missing) and get its name when it arrives."""
    w, g, a, b = trio()
    set_skills(a, [("Enchanting", 375, 375), ("Alchemy", 375, 375)])
    w.tick(5)
    open_craft(a, "Enchanting", ENCHANTING)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    w.tick(SYNC)
    b.eval("__MOCK.spells_uncached = true")
    b.relog()
    teach_names(b)
    w.tick(1)
    rs = b.eval_py("local o = {} for _, r in ipairs(%s:GetRecipes()) do o[#o + 1] = r.name end return o" % P)
    assert len(rs) == 8, rs                                   # every recipe, named or not
    assert len(b.eval_py("return %s:GetMemberRecipes(..., 333)" % P, K("Alfa"))) == 3
    w.tick(5)
    rs = b.eval_py("local o = {} for _, r in ipairs(%s:GetRecipes()) do o[#o + 1] = r.name end return o" % P)
    assert sorted(rs) == sorted(n for n, _, _ in ENCHANTING + ALCHEMY), rs
    # an id the client never names still shows (and the lookups stop)
    b.eval("__MOCK.spells_uncached = true; C_Spell.RequestLoadSpellData = function() end; __MOCK.spell_loaded = {}")
    b.eval("%s:GetRecipes()" % P)
    b.relog()
    w.tick(60)
    assert len(b.eval_py("return %s:GetRecipes()" % P)) == 8
    w.assert_no_errors()


@case
def the_roster_shows_online_state_and_level():
    w = World()
    g = Client(w, "Gina", class_file="PALADIN", guild_rank=0)
    a = Client(w, "Alfa", class_file="MAGE", level=64)
    b = Client(w, "Bert", class_file="ROGUE")
    w.add_offline_member("Zed", "WARRIOR", 3, level=31)
    for x in (g, a, b):
        x.load_addon()
        teach_names(x)
        set_skills(x, [])
    w.tick(SYNC)
    b.eval("__MOCK.roster_status = { ['Gina-Thunderstrike'] = 1 }; C_GuildInfo.GuildRoster()")
    w.tick(2)
    b.slash("/dz members")
    w.tick(1)
    rows = {r["name"]: r for r in roster_rows(b)}
    assert (rows["Alfa"]["status"], rows["Alfa"]["level"]) == ("online", 64), rows["Alfa"]
    assert rows["Gina"]["status"] == "afk" and rows["Zed"]["status"] == "offline" and rows["Zed"]["level"] == 31, rows
    assert rows["Bert"]["status"] == "online"
    a.logout()
    w.tick(3)
    assert {r["name"]: r for r in roster_rows(b)}["Alfa"]["status"] == "offline"
    w.assert_no_errors()


def version_icon(cl, name):
    """Hovers a member's roster row; returns the tooltip text (the DisasterZone they run is in it; the rows carry no
    version mark of their own) and whether the row has a version mark."""
    return cl.eval_py("""
      local want = ...
      local out
      ns.MembersUI:GetPanel().roster.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.key == want then
          row:GetScript("OnEnter")(row)
          local lines = {}
          for i = 1, GameTooltip:NumLines() do lines[#lines + 1] = _G["GameTooltipTextLeft" .. i]:GetText() end
          row:GetScript("OnLeave")(row)
          out = { mark = row.version ~= nil, tip = table.concat(lines, " | ") }
        end
      end)
      return out""", K(name))


@case
def the_roster_shows_which_version_a_member_runs():
    w = World()
    g = Client(w, "Gina", class_file="PALADIN", guild_rank=0)
    a = Client(w, "Alfa", class_file="MAGE")
    b = Client(w, "Bert", class_file="ROGUE")
    o = Client(w, "Olaf", class_file="HUNTER")
    n = Client(w, "Nina", class_file="DRUID")
    w.add_offline_member("Zed", "WARRIOR", 3)
    for x in (g, a, b, o, n):
        x.load_addon()
        teach_names(x)
        set_skills(x, [])
    w.tick(SYNC)
    b.slash("/dz members")
    w.tick(1)
    mine = b.eval("return ns.version")
    v = version_icon(b, "Bert")
    assert not v["mark"] and ("DisasterZone " + mine) in v["tip"], v
    assert "same version as yours" in v["tip"] and "Last heard" not in v["tip"], v
    v = version_icon(b, "Alfa")
    assert ("DisasterZone " + mine) in v["tip"] and "Last heard" in v["tip"], v
    v = version_icon(b, "Zed")
    assert "not seen" in v["tip"], v
    assert b.eval("return (ns.MembersUI:GetVersion(...))", K("Zed")) == "none"
    # Olaf's last message came from an older release, Nina's from a newer one
    b.eval("ns.db.peers[...].v = '0.9.0'", K("Olaf"))
    b.eval("ns.db.peers[...].v = '99.0.0'", K("Nina"))
    b.eval("ns.MembersUI:Refresh()")
    v = version_icon(b, "Olaf")
    assert "DisasterZone 0.9.0" in v["tip"] and "Older than your" in v["tip"], v
    v = version_icon(b, "Nina")
    assert "DisasterZone 99.0.0" in v["tip"] and "you are behind" in v["tip"], v
    # a member's card names the DisasterZone they run when it is not mine: last on the meta line (dropped first when
    # the line is too long), always in the header's tooltip
    header = """
      local right = ns.MembersUI:GetPanel().right
      right.headHit:GetScript("OnEnter")(right.headHit)
      local lines = {}
      for i = 1, GameTooltip:NumLines() do lines[#lines + 1] = _G["GameTooltipTextLeft" .. i]:GetText() end
      right.headHit:GetScript("OnLeave")(right.headHit)
      return { meta = table.concat(right.metaParts, " | "), tip = table.concat(lines, " | ") }"""
    b.eval("ns.MembersUI:SelectMember(...)", K("Olaf"))
    h = b.eval_py(header)
    assert h["meta"].endswith("0.9.0") and "DisasterZone 0.9.0" in h["tip"], h
    b.eval("ns.MembersUI:SelectMember(...)", K("Alfa"))
    h = b.eval_py(header)
    assert mine not in h["meta"] and ("DisasterZone " + mine) in h["tip"], h
    w.assert_no_errors()


def specs(cl, name):
    out = cl.eval_py("return %s:GetSpecs(...)" % P, K(name))
    return out and [(x.get("sp"), x["tab"], x.get("points")) for x in out]


@case
def specs_come_from_my_bis_and_else_from_the_talents():
    w, g, a, b = trio()
    # Gina (paladin): primary talents Holy, secondary Retribution, but Retribution is her main in My BiS
    g.eval("__MOCK.talents2 = { 5, 8, 48 }")
    g.set_talents((45, 16, 0))
    g.eval("ns.BiS:SetSpec('Retribution')")
    w.tick(SYNC)
    for cl in (a, b, g):
        assert specs(cl, "Gina") == [(3, 3, [5, 8, 48]), (None, 1, [45, 16, 0])], (cl.name, specs(cl, "Gina"))
    # an off spec picked in My BiS wins over the other talent set
    g.eval("ns.BiS:SetSpec('Protection', 'os')")
    w.tick(SYNC)
    assert specs(b, "Gina") == [(3, 3, [5, 8, 48]), (2, 2, None)], specs(b, "Gina")
    # without a pick in My BiS: primary talents = main, secondary = off
    b.eval("ns.BiS:GetData().sp = ''; __MOCK.talents2 = { 41, 20, 0 }")
    b.set_talents((0, 42, 19))
    w.tick(SYNC)
    assert specs(a, "Bert") == [(None, 2, [0, 42, 19]), (None, 1, [41, 20, 0])], specs(a, "Bert")
    # one talent set and no off spec: a main spec only
    assert len(specs(b, "Alfa")) == 1, specs(b, "Alfa")
    a.slash("/dz members")
    w.tick(1)
    a.eval("%s:SelectMember(...)" % UI, K("Gina"))
    assert a.find_text("Retribution") and a.find_text("Protection") and a.find_text("off spec")
    # garbage in a record is refused whole
    for bad in ("ts = { 1, 2 }", "ms = 99", "os = 'x'"):
        b.eval('ns.Comm:Send({ t = "PFB", l = { { k = ..., v = GetServerTime(), p = {}, %s } } }, "GUILD", nil, "member")' % bad,
               K("Gina"))
    w.tick(5)
    assert specs(a, "Gina") == [(3, 3, [5, 8, 48]), (2, 2, None)]
    w.assert_no_errors()


def alt_world():
    """Alfa and Alto are one player (one account: Alfa's client holds both records as its own); Alto knows Tailoring."""
    w, c = guild([("Gina", "PALADIN"), ("Alfa", "MAGE"), ("Alto", "PRIEST"), ("Bert", "ROGUE")])
    g, a, o, b = c["Gina"], c["Alfa"], c["Alto"], c["Bert"]
    set_skills(a, [("Alchemy", 375, 375)])
    set_skills(o, [("Tailoring", 375, 375)])
    w.tick(5)
    open_tradeskill(o, "Tailoring", TAILORING)
    w.tick(SYNC)
    o.logout()                                  # (one account: only one of its characters is online)
    w.tick(3)
    a.eval("DisasterZoneDB.prof[ns.Guild:GetGuildKey()][...].own = true", K("Alto"))
    return w, g, a, o, b


@case
def alts_sit_under_their_main():
    w, g, a, o, b = alt_world()
    assert a.eval_py("return %s:GetOwnCharacters()" % P) == [K("Alfa"), K("Alto")]
    assert b.eval("return %s:GetMain(...)" % P, K("Alto")) == K("Alto")
    assert a.eval("return %s:SetMain(...)" % P, K("Alfa")) is True
    w.tick(30)
    for cl in (a, b, g):
        assert cl.eval("return %s:GetMain(...)" % P, K("Alto")) == K("Alfa"), cl.name
        assert cl.eval("return %s:GetMain(...)" % P, K("Alfa")) == K("Alfa"), cl.name
        assert cl.eval_py("return %s:GetOtherCharacters(...)" % P, K("Alfa")) == [K("Alto")], cl.name
    b.slash("/dz members")
    w.tick(1)
    rows = roster_rows(b)
    names = [(r["name"], r["alt"]) for r in rows]
    assert names[:2] == [("Alfa", False), ("Alto", True)], names          # the offline alt right under its main
    b.eval("%s:SelectMember(...)" % UI, K("Alfa"))
    assert detail(b)[0]["kind"] == "prof"                                 # the card opens on Professions
    b.eval("%s:SetCard('chars')" % UI)
    d = detail(b)
    assert [(x["kind"], x.get("key"), x.get("main")) for x in d[:1]] == [("char", K("Alto"), False)], d
    b.eval("%s:SelectMember(...)" % UI, K("Alto"))
    d = detail(b)
    assert (d[0]["kind"], d[0]["key"], d[0]["main"]) == ("char", K("Alfa"), True), d
    assert b.find_text("Whisper Alfa")                                   # the player is on the main right now
    # a recipe of the offline alt: its player can be whispered on the character that is online
    b.eval("%s:ShowRecipe(31456)" % UI)
    d = [x for x in detail(b) if x["kind"] == "crafter"]
    assert [(x["key"], x["via"], x["whisper"]) for x in d] == [(K("Alto"), K("Alfa"), True)], d
    b.eval("""
      ns.MembersUI:GetPanel().right.list.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.kind == "crafter" then row.w.whisper:Click() end
      end)""")
    assert b.eval("return __MOCK.opened_chat").startswith("/w Alfa "), b.eval("return __MOCK.opened_chat")
    # my own view: the main line with Change; unlinking again
    a.slash("/dz members")
    w.tick(1)
    a.eval("%s:SetCard('chars')" % UI)
    d = detail(a)
    assert any(x["kind"] == "main" and "your main" in x["text"] for x in d), d
    assert a.eval("return %s:SetMain(nil)" % P) is True
    w.tick(30)
    assert g.eval("return %s:GetMain(...)" % P, K("Alto")) == K("Alto")
    # only my own characters can be my main
    res = b.eval_py("local ok, err = %s:SetMain(...); return { ok = ok, err = err }" % P, K("Gina"))
    assert res["ok"] is False, res
    w.assert_no_errors()


@case
def a_chain_of_alts_or_a_stranger_as_main_is_ignored():
    w, g, a, b = trio()
    w.tick(SYNC)
    # Bert says his main is somebody outside the guild; Alfa -> Gina while Gina -> Bert (a chain)
    for who, main in (("Bert", "Stranger"), ("Alfa", "Gina"), ("Gina", "Bert")):
        g.eval("local b = DisasterZoneDB.prof[ns.Guild:GetGuildKey()]; b[...].a = select(2, ...)", K(who), K(main))
    g.eval("ns:Fire('PROFESSIONS_UPDATED')")
    assert g.eval("return %s:GetMain(...)" % P, K("Bert")) == K("Bert")
    assert g.eval("return %s:GetMain(...)" % P, K("Alfa")) == K("Alfa")        # Gina is an alt herself
    assert g.eval("return %s:GetMain(...)" % P, K("Gina")) == K("Gina")        # (Bert names a main himself)
    g.slash("/dz members")
    w.tick(1)
    assert len(roster_rows(g)) == 3
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Gear
# ------------------------------------------------------------------------------------------------------------------
HELM, NECK = 29086, 29381     # Judgement Crown, Choker of Vile Intent


@case
def everyone_sees_everyones_gear_but_not_their_lists():
    w, g, a, b = trio()
    a.equip({1: HELM, 2: NECK})
    w.tick(SYNC)
    # Bert (no council) gets Alfa's gear with her professions summary, nothing of her BiS list
    gear = b.eval_py("local g = %s:GetGear(...); local o = {}; for sid, id in pairs(g or {}) do o[tostring(sid)] = id end; "
                     "return o" % P, K("Alfa"))
    assert gear == {"1": HELM, "2": NECK}, gear
    assert b.eval("return ns.Store:Get(...) == nil", K("Alfa")) is True, "a raider got someone's BiS list"
    # the Equipment card: one line per slot, Head and Neck filled, a line saying when it was shared
    b.slash("/dz members")
    w.tick(1)
    b.eval("%s:SelectMember(...)" % UI, K("Alfa"))
    b.eval("%s:SetCard('gear')" % UI)
    d = detail(b)
    assert d[0]["kind"] == "source" and "last shared" in d[0]["text"], d[0]
    items = b.eval_py("local o = {}; for _, d in ipairs(ns.MembersUI:GetPanel().right.list:GetData()) do "
                      "if d.kind == 'gear' then o[#o + 1] = d.item or 0 end end; return o")
    assert len(items) == 17 and items[0] == HELM and items[1] == NECK and items[2] == 0, items
    # a change of gear reaches the guild (at most every two minutes)
    a.equip({1: None})
    w.tick(SYNC)
    assert b.eval("return (%s:GetGear(...))[1]" % P, K("Alfa")) is None
    # my own card shows what I wear now
    a.slash("/dz members")
    w.tick(1)
    a.eval("%s:SelectMember(...)" % UI, K("Alfa"))
    a.eval("%s:SetCard('gear')" % UI)
    assert "What you wear now" in detail(a)[0]["text"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Officer notes
# ------------------------------------------------------------------------------------------------------------------
def officers():
    """Gina = GM (rank 0), Otto = officer (rank 1), Cora = rank 2, Sam = member."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Otto", 1, "WARRIOR"), ("Cora", 2, "MAGE"), ("Sam", 3, "ROGUE")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
        set_skills(x, [])
    w.tick(5)
    return w, c


def note(cl, name):
    r = cl.eval_py("return %s:Get(...)" % N, K(name))
    return r and r["text"]


def set_note(cl, name, text):
    return cl.eval_py("local ok, err = %s:Set(...); return { ok = ok, err = err }" % N, K(name), text)


@case
def officer_notes_stay_between_officers():
    w, c = officers()
    gina, otto, cora, sam = c["Gina"], c["Otto"], c["Cora"], c["Sam"]
    assert [x.eval("return %s:CanUse()" % N) for x in (gina, otto, cora, sam)] == [True, True, False, False]
    start = len(w.addon_log)
    long_text = "Reliable healer, raids Wed/Sun.\nAsked for a trial as a resto druid alt - " + "x" * 300
    assert set_note(gina, "Sam", long_text)["ok"] is True
    w.tick(5)
    assert note(gina, "Sam") == long_text and note(otto, "Sam") == long_text
    # it went to the officer only, as a whisper; nobody else holds it
    sent = [e for e in w.addon_log[start:] if e["sender"] == gina.full_name and e["prefix"] == "CDLd"]
    assert sent and all(e["chat_type"] == "WHISPER" and e["target"].split("-")[0] == "Otto" for e in sent), sent
    for x in (cora, sam):
        assert note(x, "Sam") is None
        assert x.eval("return DisasterZoneDB.officerNotes == nil or next(DisasterZoneDB.officerNotes) == nil") is True, x.name
    # members can't write one, and a note sent by a member is not taken
    res = set_note(sam, "Gina", "hello")
    assert res["ok"] is False and "officers" in res["err"], res
    sam.eval("""ns.Comm:Send({ t = "ON", k = ..., n = "forged", v = GetServerTime() + 5, by = "Gina-Thunderstrike" },
        "WHISPER", "Otto-Thunderstrike", "data")""", K("Sam"))
    sam.eval("""ns.Comm:Send({ t = "ONI", i = {} }, "WHISPER", "Otto-Thunderstrike", "data")""")
    w.tick(5)
    assert note(otto, "Sam") == long_text
    assert not [e for e in w.addon_log[start:] if e["sender"] == otto.full_name and e["chat_type"] == "WHISPER"
                and e["target"].split("-")[0] == "Sam" and e["prefix"] == "CDLd"]
    # the newer edit wins on both; an empty text removes it
    assert set_note(otto, "Sam", "Trial passed.")["ok"] is True
    w.tick(5)
    assert note(gina, "Sam") == "Trial passed."
    assert set_note(gina, "Sam", "")["ok"] is True
    w.tick(5)
    assert note(otto, "Sam") is None and note(gina, "Sam") is None
    # limits: too long, colour codes stripped, only guild members
    assert set_note(gina, "Sam", "y" * 601)["ok"] is False
    assert set_note(gina, "Stranger", "x")["ok"] is False
    assert set_note(gina, "Sam", "|cffff0000red|r")["ok"] is True
    assert note(gina, "Sam") == "cffff0000redr"
    w.assert_no_errors()


@case
def an_officer_who_logs_in_later_gets_the_notes():
    w, c = officers()
    gina, otto, sam = c["Gina"], c["Otto"], c["Sam"]
    otto.logout()
    w.tick(3)
    assert set_note(gina, "Sam", "Written while Otto was offline.")["ok"] is True
    assert set_note(gina, "Cora", "Second note.")["ok"] is True
    otto.login()
    w.tick(120)
    assert note(otto, "Sam") == "Written while Otto was offline." and note(otto, "Cora") == "Second note."
    # and the other way round: Otto writes while Gina is away
    gina.logout()
    w.tick(3)
    assert set_note(otto, "Sam", "Otto's newer note.")["ok"] is True
    gina.login()
    w.tick(120)
    assert note(gina, "Sam") == "Otto's newer note."
    # the notes survive a reload; a demoted officer no longer reads them
    otto.relog()
    w.tick(5)
    assert note(otto, "Cora") == "Second note."
    w.assert_no_errors()


@case
def the_members_tab_shows_the_note_to_officers_only():
    w, c = officers()
    gina, sam = c["Gina"], c["Sam"]
    assert set_note(gina, "Sam", "Bring flasks.")["ok"] is True
    for cl in (gina, sam):
        cl.slash("/dz members")
        w.tick(1)
        cl.eval("%s:SelectMember(...)" % UI, K("Sam"))
    assert gina.eval("return %s:GetPanel().right.note:IsShown()" % UI) is True
    assert gina.find_text("Bring flasks.") and gina.find_text("Officer note")
    assert sam.eval("return %s:GetPanel().right.note:IsShown()" % UI) is False
    assert not sam.find_text("Officer note")
    # Edit opens the text box; OK saves
    gina.eval("%s:GetPanel().right.note.edit:Click()" % UI)
    w.tick(0.2)
    assert gina.find_text("Officer note for Sam")
    gina.eval("""
      local f
      for _, child in ipairs({ UIParent:GetChildren() }) do
        if child.multi and child.ok and child:IsShown() then f = child end
      end
      f.multi:SetText("Bring flasks and food.")
      f.ok:Click()""")
    w.tick(1)
    assert note(gina, "Sam") == "Bring flasks and food."
    assert gina.find_text("Bring flasks and food.")
    w.assert_no_errors()


@case
def the_header_buttons_are_clickable_over_the_hover_area():
    # the name's hover area (the member tooltip) stopped covering the share / note icons in game: it ends left of the
    # buttons and they sit above it
    w, c = officers()
    gina = c["Gina"]
    gina.slash("/dz members")
    w.tick(1)
    for name in ("Sam", "Gina"):
        gina.eval("%s:SelectMember(...)" % UI, K(name))
        r = gina.eval_py("""
          local right = ns.MembersUI:GetPanel().right
          local hit, used, lvl = right.headHit, 0, true
          for _, b in ipairs({ right.whisper, right.share, right.addNote, right.onMap }) do
            if b:IsShown() then
              used = used + b:GetWidth() + 6
              lvl = lvl and b:GetFrameLevel() > hit:GetFrameLevel()
            end
          end
          local x
          for i = 1, hit:GetNumPoints() do
            local pt, rel, _, px = hit:GetPoint(i)
            if pt == "TOPRIGHT" and rel == right then x = px end
          end
          return { x = x, used = used, above = lvl, share = right.share:IsShown() }""")
        assert r["share"] is True, r
        assert r["x"] is not None and -r["x"] >= r["used"], (name, r)
        assert r["above"] is True, (name, r)
    w.assert_no_errors()


@case
def a_debug_role_sees_the_notes_ui_without_touching_the_real_notes():
    """The developer's character (Tsumil) pretending to be GM / officer: the notes UI works with test notes that stay
    on that PC; nothing is sent, no real note arrives, and the real officers' notes are untouched."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Otto", 1, "WARRIOR"), ("Tsumil", 3, "ROGUE"), ("Sam", 3, "MAGE")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
        set_skills(x, [])
    w.tick(5)
    gina, otto, tsu = c["Gina"], c["Otto"], c["Tsumil"]
    assert set_note(gina, "Sam", "The real note.")["ok"] is True
    w.tick(5)
    assert tsu.eval("return %s:CanUse()" % N) is False
    for role in ("gm", "officer"):
        tsu.slash("/dz role " + role)
        w.tick(1)
        assert tsu.eval("return %s:CanUse()" % N) is True and tsu.eval("return %s:IsLocalOnly()" % N) is True, role
    assert note(tsu, "Sam") is None                              # the real note never reached this client
    start = len(w.addon_log)
    assert set_note(tsu, "Sam", "A test note.")["ok"] is True
    w.tick(120)
    assert note(tsu, "Sam") == "A test note."
    assert not [e for e in w.addon_log[start:] if e["sender"] == tsu.full_name and e["chat_type"] == "WHISPER"
                and e["prefix"] != "CDLb"   # (the feedback sync's login whisper: not a note)
                and e["prefix"] != "CDLr"]   # (CDLr: the dungeon board, Core/DungeonRuns.lua)
    assert note(gina, "Sam") == "The real note." and note(otto, "Sam") == "The real note."
    # a real officer editing meanwhile, and a login exchange: still nothing for the pretender
    assert set_note(otto, "Sam", "Edited by Otto.")["ok"] is True
    otto.relog()
    w.tick(120)
    assert note(tsu, "Sam") == "A test note."
    assert not [e for e in w.addon_log[start:] if e["chat_type"] == "WHISPER" and e["prefix"] == "CDLd"
                and str(e["target"]).split("-")[0] == "Tsumil"]
    tsu.slash("/dz members")
    w.tick(1)
    tsu.eval("%s:SelectMember(...)" % UI, K("Sam"))
    assert tsu.eval("return %s:GetPanel().right.note:IsShown()" % UI) is True
    assert tsu.find_text("A test note.") and tsu.find_text("kept on this PC only")
    # the role off: no notes UI; the test notes sit apart from where real notes would go
    tsu.slash("/dz role off")
    w.tick(1)
    assert tsu.eval("return %s:CanUse()" % N) is False and note(tsu, "Sam") is None
    assert tsu.eval("return %s:GetPanel().right.note:IsShown()" % UI) is False
    gk = tsu.eval("return ns.Guild:GetGuildKey()")
    assert tsu.eval("return DisasterZoneDB.officerNotes[...] == nil", gk) is True
    assert tsu.eval("return DisasterZoneDB.officerNotes['debug ' .. ...] ~= nil", gk) is True
    # a real officer pretending to be a raider keeps receiving (only the screen changes)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
