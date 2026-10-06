"""Party invites from a run's leader (Core/DungeonRuns.lua) and my run in Blizzard's Group Finder (Core/GroupFinder.lua,
the Dungeons tab's rows), on the real addon.

Covers: an invite from a run I asked to join is accepted for me and Blizzard's pop-up never stays; an invite I didn't
ask for is the run's own pop-up (Accept joins, the cross declines, nobody answering declines after a minute, a ping
doesn't push it out); invites from anyone else keep Blizzard's pop-up; the Group Finder listing and search happen only
inside a click (WoW blocks them otherwise) and pick the run's activity; the candidates (solo players listed for the
dungeon whose roles fit, whispers while listed; guild members, groups, other dungeons and players set aside left out);
inviting one puts them in the run as the role they fit; Unlist takes the listing down; the List a run sheet lists with
the same click; a run for later meant for the Group Finder prompts when it starts; demo mode.

Run: luaenv\\Scripts\\python.exe tests\\dungeons\\test_group_finder.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50

# the mock's Group Finder activity ids (wowmock/game.lua): 1100 + i normal, 1200 + i heroic, i = LFG_DUNGEONS order
BOTANICA_H = 1212
BOTANICA_N = 1112
MECHANAR_H = 1211


def guild(names, tick=HELLO, pugs=()):
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for name, cls in pugs:
        c[name] = Client(w, name, class_file=cls, guild=None)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def five(pugs=()):
    return guild([("Gina", "PALADIN"), ("Alfa", "PRIEST"), ("Bert", "WARRIOR"), ("Cara", "MAGE"), ("Dora", "ROGUE")],
                 pugs=pugs)


def K(cl):
    return cl.full_name


def roles(cl, *on):
    for r in on:
        cl.eval("ns.DungeonRuns:SetMyRole(...)", r, True)
    for r in ("tank", "healer", "dps"):
        if r not in on:
            cl.eval("ns.DungeonRuns:SetMyRole(...)", r, False)


def list_run(cl, d="Botanica", heroic=True, role="healer", at=0):
    rid = cl.eval_py("local r, why = ns.DungeonRuns:List({ d = select(1, ...), h = select(2, ...), role = select(3, ...),"
                     " at = select(4, ...) }); return r and r.id or why", d, heroic, role, at)
    assert isinstance(rid, str) and ":" in rid, rid
    return rid


def blizzard_popup(cl):
    return cl.eval_py("return StaticPopup_FindVisible('PARTY_INVITE') ~= nil")


def toast(cl):
    return cl.eval_py("local t = ns.DungeonsUI:GetToast(); if not (t and t:IsShown()) then return nil end; "
                      "return { run = t.run, mode = t.mode, l2 = t.t2:GetText(), btn = t.btn:GetText() }")


def slots(cl, rid):
    return cl.eval_py("""
      local out = {}
      for _, x in ipairs(ns.DungeonRuns:GetSlots(ns.DungeonRuns:GetRun(...))) do
        out[#out + 1] = x.empty and ('open:' .. x.role) or (x.key .. ':' .. x.role)
      end
      return out""", rid) or []


def my_card(cl):
    return "ns.DungeonsUI:GetPanel().cards[1]"


def lfg_log(cl):
    return cl.eval_py("local out = {}; for i, e in ipairs(__MOCK.lfg_log) do out[i] = { fn = e.fn, "
                      "a = e.activityIDs and e.activityIDs[1], comment = e.comment } end; return out") or []


def cands(cl):
    return cl.eval_py("local out = {}; for _, e in ipairs(ns.GroupFinder:GetCandidates()) do out[#out + 1] = "
                      "{ key = e.key, role = e.role, w = e.whispered or false, text = e.text, inv = e.invited or false }"
                      " end; return out") or []


def menu_pick(cl, word):
    """Opens my run's More menu and picks the entry whose text has `word`."""
    cl.eval("ns.DungeonsUI:OpenMineMenu(" + my_card(cl) + ".more)")
    texts = cl.eval_py("local out = {}; for _, e in ipairs(__MOCK.menu_export().children) do "
                       "out[#out + 1] = e.text or '' end; return out")
    hits = [x for x in texts if word in x]
    assert hits, (word, texts)
    cl.menu_select(hits[0])


def open_tab(w, cl):
    cl.eval("ns.MainFrame:Open('dungeons')")
    w.tick(0.5)


RESULTS = """
__MOCK.lfg_set_results({
  { name = 'Holyhoof', class = 'PALADIN', level = 70, roles = { healer = true }, comment = 'holy pala, keyed',
    activityIDs = { 1212 } },
  { name = 'Shieldwall', class = 'WARRIOR', level = 70, roles = { tank = true, dps = true }, activityIDs = { 1212, 1211 } },
  { name = 'Lowbie', class = 'WARRIOR', level = 68, roles = { tank = true }, activityIDs = { 1212 } },
  { name = 'Alfa', class = 'PRIEST', level = 70, roles = { healer = true }, activityIDs = { 1212 } },
  { name = 'Partyleader', class = 'MAGE', level = 70, roles = { dps = true }, activityIDs = { 1212 }, numMembers = 3 },
  { name = 'Elsewhere', class = 'ROGUE', level = 70, roles = { dps = true }, activityIDs = { 1211 } },
  { name = 'Stabby', class = 'ROGUE', level = 70, roles = { dps = true }, comment = 'any heroic', activityIDs = { 1212 } },
})"""


# ------------------------------------------------------------------------------------------------------------------
@case
def an_invite_from_a_run_i_asked_to_join_is_accepted_for_me():
    w, c = five()
    w.auto_accept_invites = False
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    rid = list_run(g, "ShatteredHalls", True, "healer")
    w.tick(3)
    assert b.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    w.tick(2)
    assert g.eval_py("return ns.DungeonRuns:Accept(...)", rid, K(b)) is True
    w.tick(3)
    # no pop-up stayed (not Blizzard's, not the run's) and Bert is in Gina's party as her tank
    assert blizzard_popup(b) is False
    assert toast(b) is None or toast(b)["mode"] != "invite", toast(b)
    assert any(e["by"] == K(g) and e["target"].startswith("Bert") and e["result"] == "joined" for e in w.invite_log), \
        w.invite_log
    assert any("Joining Gina's run" in line for line in b.chat_frame), b.chat_frame
    w.tick(3)
    assert slots(c["Cara"], rid)[0] == K(b) + ":tank", slots(c["Cara"], rid)
    w.assert_no_errors()


@case
def an_invite_i_did_not_ask_for_is_the_runs_own_popup():
    w, c = five()
    w.auto_accept_invites = False
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    roles(b, "tank")
    roles(cara, "dps")
    rid = list_run(g, "ShatteredHalls", True, "healer")
    w.tick(3)
    # Gina invites Bert straight away (he never asked): Blizzard's pop-up goes, the run's pop-up asks
    assert g.eval_py("return ns.DungeonRuns:InviteFree(...)", K(b)) is True
    w.tick(1)
    assert blizzard_popup(b) is False
    t = toast(b)
    assert t and t["run"] == rid and t["mode"] == "invite" and t["btn"] == "Accept" and "invites you" in t["l2"], t
    assert b.eval_py("return ns.DungeonRuns:GetInvite().run") == rid
    # the invite is still open (hiding Blizzard's pop-up didn't decline it)
    assert w.invite_log[-1]["result"] == "pending", w.invite_log[-1]
    # Bert's board: the run's button accepts too
    open_tab(w, b)
    assert b.eval_py("local c = ns.DungeonsUI:GetPanel().cards[1]; return c.btn:IsShown() and c.btn:GetText()") \
        == "Accept"
    # a ping for another run doesn't push the invite out
    roles(cara, "dps")
    b.eval("ns.DungeonsUI:OnPing(...)", rid)
    assert toast(b)["mode"] == "invite"
    # Accept on the pop-up: Bert joins
    b.click(b.eval("return ns.DungeonsUI:GetToast().btn"))
    w.tick(3)
    assert w.invite_log[-1]["result"] == "joined", w.invite_log[-1]
    assert toast(b) is None
    assert b.eval_py("return ns.DungeonRuns:GetInvite()") is None
    # Cara gets one too and says no with the cross
    assert g.eval_py("return ns.DungeonRuns:InviteFree(...)", K(cara)) is True
    w.tick(1)
    assert toast(cara)["mode"] == "invite"
    cara.click(cara.eval("return ns.DungeonsUI:GetToast().x"))
    w.tick(1)
    assert w.invite_log[-1]["result"] == "declined", w.invite_log[-1]
    assert toast(cara) is None and blizzard_popup(cara) is False
    assert any("declines your group invitation" in line for line in g.chat_frame), g.chat_frame
    w.assert_no_errors()


@case
def an_invite_nobody_answers_runs_out_and_old_requests_ask_again():
    w, c = five()
    w.auto_accept_invites = False
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    rid = list_run(g, "Arcatraz", True, "healer")
    w.tick(3)
    g.eval("ns.DungeonRuns:InviteFree(...)", K(b))
    w.tick(1)
    assert toast(b)["mode"] == "invite"
    w.tick(61)
    assert toast(b) is None
    assert w.invite_log[-1]["result"] == "declined", w.invite_log[-1]
    # a request from 11 minutes ago is no answer any more: the pop-up asks
    assert b.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    b.eval("ns.DungeonRuns:GetAsked(...).at = GetServerTime() - 11 * 60", rid)
    w.tick(2)
    g.eval("ns.DungeonRuns:Accept(...)", rid, K(b))
    w.tick(1)
    assert toast(b)["mode"] == "invite", toast(b)
    assert w.invite_log[-1]["result"] == "pending"
    w.assert_no_errors()


@case
def invites_from_anyone_else_keep_blizzards_popup():
    w, c = five()
    w.auto_accept_invites = False
    g, b, cara, dora = c["Gina"], c["Bert"], c["Cara"], c["Dora"]
    list_run(g, "Botanica", True, "healer")
    w.tick(3)
    # Cara has no run: her invite is Blizzard's business
    cara.eval("C_PartyInfo.InviteUnit('Dora')")
    w.tick(1)
    assert blizzard_popup(dora) is True
    assert toast(dora) is None or toast(dora)["mode"] != "invite"
    assert dora.eval_py("return ns.DungeonRuns:GetInvite()") is None
    # an invite whose acceptance would cost a queue keeps Blizzard's pop-up (it says so)
    b.eval("__MOCK.invite_removes_queues = true")
    g.eval("ns.DungeonRuns:InviteFree(...)", K(b))
    w.tick(1)
    assert blizzard_popup(b) is True
    assert b.eval_py("return ns.DungeonRuns:GetInvite()") is None
    w.assert_no_errors()


@case
def the_group_finder_lists_and_searches_only_inside_a_click():
    w, c = five()
    g = c["Gina"]
    rid = list_run(g, "Botanica", True, "healer")
    w.tick(3)
    assert g.eval_py("return (ns.GroupFinder:GetActivity('Botanica', true))") == BOTANICA_H
    assert g.eval_py("return (ns.GroupFinder:GetActivity('Botanica', false))") == BOTANICA_N
    # called outside a click: WoW blocks it (and the harness records the block as an error)
    g.eval("ns.GroupFinder:List()")
    w.tick(0.5)
    errs = w.errors()
    assert errs and "ADDON_ACTION_BLOCKED" in errs[0] and "CreateListing" in errs[0], errs
    w.clear_errors()
    assert g.eval_py("return (ns.GroupFinder:GetListing(ns.DungeonRuns:GetMine()))") is False
    # the eye on the run card (between Share and More): not listed, still
    g.eval(RESULTS)
    open_tab(w, g)
    eye = my_card(g) + ".eye"
    assert g.eval_py("local e = " + eye + "; return e:IsShown() and not e.looking") is True
    assert g.eval_py("local c = " + my_card(g) + "; local _, rel = c.share:GetPoint(1); return rel == c.eye") is True
    assert g.eval_py("return " + eye + ".tipLines[1]") == "Group Finder"
    g.click(g.eval("return " + eye))
    w.tick(1)
    log = lfg_log(g)
    assert [e["fn"] for e in log] == ["CreateListing", "Search"], log
    assert log[0]["a"] == BOTANICA_H and log[1]["a"] == BOTANICA_H and log[0]["comment"] == "", log
    listed = g.eval_py("local a, b = ns.GroupFinder:GetListing(ns.DungeonRuns:GetMine()); return { a, b }")
    assert listed == [True, True], listed
    # listed: the eye looks around (its iris moves) and says so
    assert g.eval_py("return " + eye + ".looking") is True
    assert "In the Group Finder" in g.eval_py("return " + eye + ".tipLines[1]")
    xs = []
    for _ in range(4):
        w.tick(0.6)
        xs.append(round(g.eval_py("local _, _, _, x = " + eye + ".iris:GetPoint(1); return x"), 2))
    assert len(set(xs)) > 1, xs
    # the candidates: solo players for heroic Botanica whose roles fit (the healer place is Gina's), level 70
    got = cands(g)
    assert [x["key"].split("-")[0] for x in got] == ["Shieldwall", "Stabby"], got
    assert got[0]["role"] == "tank" and got[1]["role"] == "dps" and got[1]["text"] == "any heroic", got
    shown = g.eval_py("local out = {}; for _, r in ipairs(" + my_card(g) + ".pugs) do if r:IsShown() then "
                      "out[#out + 1] = r.name:GetText() end end; return out")
    assert len(shown) == 2 and "Shieldwall" in shown[0], shown
    # Look again (the More menu) searches again
    g.eval("__MOCK.lfg_log = {}")
    menu_pick(g, "Look again")
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)] == ["Search"], lfg_log(g)
    # a player who delists leaves; one set aside too
    g.eval("__MOCK.lfg_delist('Stabby')")
    w.tick(0.5)
    assert [x["key"].split("-")[0] for x in cands(g)] == ["Shieldwall"]
    g.eval("ns.GroupFinder:Dismiss(...)", "Shieldwall-" + g.realm)
    w.tick(0.5)
    assert cands(g) == []
    # the eye again: out of the Group Finder, the eye still and no players under the run
    g.eval("__MOCK.lfg_log = {}")
    g.click(g.eval("return " + eye))
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)] == ["RemoveListing"], lfg_log(g)
    assert g.eval_py("return " + eye + ".looking") is False
    assert g.eval_py("return ns.DungeonRuns:GetMine() ~= nil") is True
    w.assert_no_errors()


@case
def whispers_while_listed_are_candidates_and_an_invited_pug_takes_the_open_role():
    w, c = five(pugs=[("Pugzug", "SHAMAN"), ("Tankard", "WARRIOR")])
    g, pz, tk = c["Gina"], c["Pugzug"], c["Tankard"]
    rid = list_run(g, "Botanica", True, "healer")
    w.tick(3)
    # a whisper before the listing is just a whisper
    pz.eval("SendChatMessage('hi', 'WHISPER', nil, 'Gina')")
    w.tick(1)
    assert cands(g) == []
    g.eval("__MOCK.lfg_set_results({ { name = 'Tankard', class = 'WARRIOR', level = 70, roles = { tank = true }, "
           "activityIDs = { 1212 } } })")
    open_tab(w, g)
    g.click(g.eval("return " + my_card(g) + ".eye"))
    w.tick(1)
    pz.eval("SendChatMessage('resto sham lf botanica, inv pls', 'WHISPER', nil, 'Gina')")
    c["Alfa"].eval("SendChatMessage('guildie whisper', 'WHISPER', nil, 'Gina')")
    w.tick(1)
    got = cands(g)
    assert [x["key"].split("-")[0] for x in got] == ["Pugzug", "Tankard"], got
    assert got[0]["w"] is True and got[0]["text"] == "resto sham lf botanica, inv pls" and got[0].get("role") is None, got
    # Invite on Tankard's row: he joins as the tank the run was missing
    rows = g.eval_py("local out = {}; for i, r in ipairs(" + my_card(g) + ".pugs) do if r:IsShown() then "
                     "out[#out + 1] = r.key end end; return out")
    assert [k.split("-")[0] for k in rows] == ["Pugzug", "Tankard"], rows
    g.click(g.eval("return " + my_card(g) + ".pugs[2].yes"))
    w.tick(4)
    assert any(e["target"].startswith("Tankard") and e["result"] == "joined" for e in w.invite_log), w.invite_log
    assert slots(c["Cara"], rid)[0] == K(tk) + ":tank", slots(c["Cara"], rid)
    # in the party now: no longer a candidate
    assert [x["key"].split("-")[0] for x in cands(g)] == ["Pugzug"]
    w.assert_no_errors()


@case
def unlist_takes_the_group_finder_listing_down():
    w, c = five()
    g = c["Gina"]
    list_run(g, "Mechanar", True, "healer")
    w.tick(3)
    open_tab(w, g)
    g.click(g.eval("return " + my_card(g) + ".eye"))
    w.tick(1)
    assert g.eval_py("return __MOCK.lfg_entry ~= nil") is True
    menu_pick(g, "Unlist")
    w.tick(1)
    assert g.eval_py("return __MOCK.lfg_entry == nil") is True
    assert g.eval_py("return ns.DungeonRuns:GetMine()") is None
    w.assert_no_errors()


@case
def the_sheet_lists_in_the_group_finder_with_the_same_click():
    w, c = five()
    g = c["Gina"]
    open_tab(w, g)
    g.eval("ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ d = 'Botanica', h = true, gf = true })")
    w.tick(0.3)
    sheet = "ns.DungeonsUI:GetPanel().sheet"
    assert g.eval_py("return " + sheet + ".gfRow:IsShown() and " + sheet + ".gf:IsOn()") is True
    assert g.eval_py("return " + sheet + ".gfText.text:GetText()") == "Also list it in the Group Finder"
    g.click(g.eval("return " + sheet + ".go"))
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)] == ["CreateListing", "Search"], lfg_log(g)
    assert g.eval_py("return ns.DungeonRuns:GetMine().gf") is True
    w.assert_no_errors()


@case
def a_later_run_meant_for_the_group_finder_prompts_when_it_starts():
    w, c = five()
    g = c["Gina"]
    at = g.eval_py("return GetServerTime() + 120")
    g.eval("ns.DungeonRuns:List({ d = 'Steamvault', h = true, role = 'healer', at = ..., gf = true })", at)
    w.tick(20, step=0.5)
    assert toast(g) is None
    w.tick(115, step=0.5)
    t = toast(g)
    assert t and t["btn"] == "List" and "open in your run" in t["l2"], t
    assert lfg_log(g) == []
    g.click(g.eval("return ns.DungeonsUI:GetToast().btn"))
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)][:1] == ["CreateListing"], lfg_log(g)
    # once only
    g.eval("__MOCK.lfg_log = {}")
    w.tick(60)
    assert toast(g) is None or toast(g)["btn"] != "List"
    w.assert_no_errors()


@case
def demo_mode_shows_made_up_pugs_and_calls_nothing():
    w, c = five()
    g = c["Gina"]
    g.eval("ns.Demo:SetEnabled(true)")
    w.tick(1)
    g.eval("ns.DungeonRuns:List({ d = 'Botanica', h = true, role = 'healer' })")
    open_tab(w, g)
    g.click(g.eval("return " + my_card(g) + ".eye"))
    w.tick(1)
    assert lfg_log(g) == []
    got = cands(g)
    assert len(got) >= 3 and got[0]["w"] is True, got
    g.click(g.eval("return " + my_card(g) + ".pugs[1].yes"))
    w.tick(1)
    assert any(x["key"].startswith("Thalindra") for x in g.eval_py(
        "local out = {}; for _, x in ipairs(ns.DungeonRuns:GetMine().s) do out[#out + 1] = { key = x.k } end; "
        "return out")), "Thalindra not in the demo run"
    w.assert_no_errors()



def listed(w, g, d="Botanica"):
    """Gina lists d (heroic) and puts it in the Group Finder with the eye."""
    rid = list_run(g, d, True, "healer")
    w.tick(3)
    open_tab(w, g)
    g.click(g.eval("return " + my_card(g) + ".eye"))
    w.tick(1)
    return rid


@case
def whispers_with_links_keep_the_name():
    w, c = five(pugs=[("Pugzug", "SHAMAN")])
    g, pz = c["Gina"], c["Pugzug"]
    listed(w, g)
    link = "|cffa335ee|Hitem:28583::::::::70:::::|h[Big Hammer]|h|r"
    pz.eval("SendChatMessage(..., 'WHISPER', nil, 'Gina')", "heal here, have " + link + " lol")
    w.tick(1)
    assert [x["text"] for x in cands(g)] == ["heal here, have [Big Hammer] lol"], cands(g)
    w.assert_no_errors()


@case
def a_pug_who_says_no_can_be_invited_again():
    w, c = five(pugs=[("Tankard", "WARRIOR")])
    w.auto_accept_invites = False
    g, tk = c["Gina"], c["Tankard"]
    g.eval("__MOCK.lfg_set_results({ { name = 'Tankard', class = 'WARRIOR', level = 70, roles = { tank = true }, "
           "activityIDs = { 1212 } } })")
    listed(w, g)
    g.click(g.eval("return " + my_card(g) + ".pugs[1].yes"))
    w.tick(1)
    assert cands(g)[0]["inv"] is True
    tk.eval("DeclineGroup()")
    w.tick(2)
    assert cands(g)[0]["inv"] is False, cands(g)
    assert g.eval_py("local r = " + my_card(g) + ".pugs[1]; return r.yes:IsShown()") is True
    w.assert_no_errors()


@case
def a_run_that_ends_by_itself_asks_to_take_its_listing_down():
    w, c = five()
    g = c["Gina"]
    listed(w, g)
    w.make_party([g, c["Alfa"], c["Bert"], c["Cara"], c["Dora"]], leader=g)   # full: off the board
    w.tick(4)
    assert g.eval_py("return ns.DungeonRuns:GetMine()") is None
    t = toast(g)
    assert t and t["btn"] == "Remove" and t["mode"] == "finder", t
    g.eval("__MOCK.lfg_log = {}")
    g.click(g.eval("return ns.DungeonsUI:GetToast().btn"))
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)] == ["RemoveListing"], lfg_log(g)
    # Unlist by hand (a click that takes the listing down too): no such pop-up
    w.disband()
    w.tick(2)
    listed(w, g, "Mechanar")
    menu_pick(g, "Unlist")
    w.tick(4)
    assert toast(g) is None or toast(g)["btn"] != "Remove"
    w.assert_no_errors()


@case
def editing_a_listed_run_keeps_the_group_finder_in_step():
    w, c = five()
    g = c["Gina"]
    listed(w, g)
    # another dungeon: the listing switches with the Save click
    g.eval("__MOCK.lfg_log = {}")
    g.eval("ns.DungeonsUI:OpenSheet(true); ns.DungeonsUI:SetSheet({ d = 'Mechanar' })")
    g.click(g.eval("return ns.DungeonsUI:GetPanel().sheet.go"))
    w.tick(1)
    log = lfg_log(g)
    assert log and log[0]["fn"] == "UpdateListing" and log[0]["a"] == MECHANAR_H, log
    # moved to later: out of the Group Finder
    g.eval("__MOCK.lfg_log = {}")
    g.eval("ns.DungeonsUI:OpenSheet(true); ns.DungeonsUI:SetSheet({ when = 'later', day = 1, mins = 20 * 60 })")
    g.click(g.eval("return ns.DungeonsUI:GetPanel().sheet.go"))
    w.tick(1)
    assert [e["fn"] for e in lfg_log(g)] == ["RemoveListing"], lfg_log(g)
    assert g.eval_py("return " + my_card(g) + ".eye:IsShown()") is False
    w.assert_no_errors()


@case
def more_players_than_rows_says_so_on_the_eye():
    w, c = five()
    g = c["Gina"]
    g.eval("""local list = {}
      for i, n in ipairs({ 'Aa', 'Bb', 'Cc', 'Dd', 'Ee', 'Ff', 'Gg' }) do
        list[i] = { name = 'Pug' .. n, class = 'MAGE', level = 70, roles = { dps = true }, activityIDs = { 1212 } }
      end
      __MOCK.lfg_set_results(list)""")
    listed(w, g)
    assert len(cands(g)) == 7
    shown = g.eval_py("local n = 0; for _, r in ipairs(" + my_card(g) + ".pugs) do if r:IsShown() then n = n + 1 "
                      "end end; return n")
    assert shown == 5, shown
    tip = g.eval_py("return " + my_card(g) + ".eye.tipLines")
    assert any("7 players found" in str(x) for x in tip), tip
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
