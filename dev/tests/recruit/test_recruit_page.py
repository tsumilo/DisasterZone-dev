"""Recruitment, step 2 (UI/Recruit.lua + the ways in): Guild > Recruitment for the GM and officers only; the list's
sections; a person's page; changes made on it (wants, nights, notes, claim, Not now) reaching the other officers;
the search adding a name; Add to Recruitment in the guest book's menu and in the game's player menus (class, level and
the guest book's note carried over); Settings > Guild > Recruitment for the GM, read-only for officers.
Run: luaenv\\Scripts\\python.exe tests\\recruit\\test_recruit_page.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, strip_codes, menu_texts, menu_pick, menu_labels  # noqa: E402

SETTLE = 45
REALM = "Thunderstrike"


def K(name):
    return name + "-" + REALM


def guild():
    """Gina GM, Bob officer, Cora member; Kaelthorn and Aurelith outside the guild."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Cora", 3, "PRIEST")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for name, cls in (("Kaelthorn", "PALADIN"), ("Aurelith", "PALADIN")):
        c[name] = Client(w, name, guild=None, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(SETTLE)
    return w, c


def person(cl, name):
    return cl.eval_py("return ns.Recruit:Get(...)", K(name))


def open_page(w, cl, who=None):
    cl.eval("ns.RecruitUI:Open(...)", K(who) if who else None)
    w.tick(0.5)


def rows(cl):
    """The list as (kind, text): ("head", "TALKING") / ("row", name) / ("add", name)."""
    return [tuple(r) for r in (cl.eval_py("""
        local out = {}
        for _, d in ipairs(ns.RecruitUI._H.Rows()) do
            if d.head then out[#out + 1] = { "head", d.head }
            elseif d.add then out[#out + 1] = { "add", d.add }
            else out[#out + 1] = { "row", (d.r.key:gsub('%-.*', '')) } end
        end
        return out""") or [])]


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


@case
def only_the_gm_and_officers_get_the_page():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    avail = "return ns.MainFrame.IsTabAvailable and ns.MainFrame:IsTabAvailable('recruit') or ns.Recruit:CanUse()"
    assert gina.eval(avail) is True and bob.eval(avail) is True
    assert cora.eval(avail) is False
    # the Guild menu lists it after Polls, with its facts
    facts = gina.eval_py("return ns.NavMenu.FACTS.recruit()")
    assert facts and lst(facts)[0][1] in ("need you", "needs you"), facts
    assert cora.eval_py("return ns.NavMenu.FACTS.recruit()") is None
    w.assert_no_errors()


@case
def the_list_puts_who_needs_you_first_and_the_page_shows_a_person():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    gina.eval("ns.Recruit:Add('Thalric-Thunderstrike', { c = 'WARRIOR', sp = 3, claim = false, ib = 'Cora-Thunderstrike', "
              "it = 'My cousin, coming back after 15 years.', src = 'intro' })")
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1, lv = 70, note = 'Lovely chat.' })")
    gina.eval("ns.Recruit:Add('Aurelith-Thunderstrike', { c = 'PALADIN', sp = 1, lv = 13 })")
    gina.eval("ns.Recruit:Update('Aurelith-Thunderstrike', { follow = { at = GetServerTime() - 60, t = 'a dungeon' } })")
    w.tick(5)
    open_page(w, bob)
    r = rows(bob)
    assert r == [("head", "UNCLAIMED"), ("row", "Thalric"), ("head", "NEEDS YOU"), ("row", "Aurelith"),
                 ("head", "TALKING"), ("row", "Kaelthorn")], r
    open_page(w, bob, "Kaelthorn")
    assert bob.find_text("Kaelthorn", True, True)
    assert bob.find_text("Holy Paladin · level 70", True, True)
    assert bob.find_text("Lovely chat.", True, True)
    assert bob.find_text("WHAT THEY'RE LOOKING FOR", True, True)
    # the unclaimed one: who introduced them, the two actions
    open_page(w, bob, "Thalric")
    assert bob.find_text("Nobody is talking with them yet. Cora introduced them today.", True, True)
    banner = bob.eval_py("local out = {} for _, f in ipairs(ns.RecruitUI:GetPanel().banner.actions) do "
                         "out[#out + 1] = f:GetText() end return out")
    assert [strip_codes(t) for t in lst(banner)] == ["I'll talk to them", "Pass to"], banner
    w.assert_no_errors()


@case
def changes_on_the_page_reach_the_other_officers():
    w, c = guild()
    gina, bob = c["Gina"], c["Bob"]
    gina.eval("ns.Recruit:Add('Kaelthorn-Thunderstrike', { c = 'PALADIN', sp = 1, claim = false })")
    w.tick(5)
    open_page(w, bob, "Kaelthorn")
    bob.eval("ns.Recruit:Claim(ns.RecruitUI:GetState().sel)")
    bob.eval("ns.RecruitUI:ToggleWant('raid'); ns.RecruitUI:ToggleNight(4); ns.RecruitUI:ToggleNight(7); "
             "ns.RecruitUI:ToggleNight(2); ns.RecruitUI:ToggleNight(2)")
    bob.eval("ns.RecruitUI:SetFollow(3, 'bring him to SSC')")
    w.tick(5)
    p = person(gina, "Kaelthorn")
    assert p["w"] == K("Bob") and lst(p["ni"]) == [4, 7] and p["wa"] == 1 and p["fu"]["t"] == "bring him to SSC", p
    # a note through the dialog
    bob.eval("ns.RecruitUI:WriteNote()")
    w.tick(0.2)
    bob.eval("local f = _G.DisasterZonePopup1; (f.multi or f.editBox):SetText('Calm, knows his class.'); ns.Popup:Click(f, 1)")
    w.tick(5)
    assert [n["t"] for n in lst(person(gina, "Kaelthorn")["n"])] == ["Calm, knows his class."]
    # Not now, from the banner
    bob.eval("ns.RecruitUI:NotNow()")
    w.tick(5)
    assert person(gina, "Kaelthorn")["st"] == "notnow"
    w.assert_no_errors()


@case
def the_search_adds_a_name():
    w, c = guild()
    gina = c["Gina"]
    open_page(w, gina)
    gina.eval("ns.RecruitUI:SetSearch('Shadowfang')")
    assert rows(gina) == [("add", "Shadowfang")]
    gina.eval("ns.RecruitUI:AddByName('Shadowfang')")
    w.tick(1)
    assert person(gina, "Shadowfang")["w"] == K("Gina")
    assert gina.eval("return ns.RecruitUI:GetState().sel") == K("Shadowfang")
    # someone already there: opens them, adds nothing twice
    gina.eval("ns.RecruitUI:SetSearch('shadow')")
    assert rows(gina)[-1] == ("row", "Shadowfang"), rows(gina)
    w.assert_no_errors()


@case
def add_to_recruitment_from_the_guest_book_and_player_menus():
    w, c = guild()
    gina, cora = c["Gina"], c["Cora"]
    # a guest with a note, starred as a recruit
    assert gina.eval("return (ns.GuestBook:SetNote('Aurelith-Thunderstrike', 'sweet, wants to learn', true, 'PALADIN', 1))") is True
    w.tick(2)
    gina.eval("ns.GuestBookUI:OpenEntryMenu(UIParent, { key = 'Aurelith-Thunderstrike' })")
    assert "Add to Recruitment" in menu_labels(gina), menu_labels(gina)
    menu_pick(gina, "Add to Recruitment")
    w.tick(1)
    p = person(gina, "Aurelith")
    assert p and p["c"] == "PALADIN" and p["sp"] == 1 and p["src"] == "guest", p
    assert lst(p["n"])[0]["t"] == "sweet, wants to learn", p
    # now the menu says Recruitment... instead
    gina.eval("ns.UI:CloseMenus(); ns.GuestBookUI:OpenEntryMenu(UIParent, { key = 'Aurelith-Thunderstrike' })")
    assert "Recruitment..." in menu_labels(gina) and "Add to Recruitment" not in menu_labels(gina)
    gina.eval("ns.UI:CloseMenus()")

    def player_menu(cl, ctx):
        return [strip_codes(t[2] or "").strip() for t in menu_texts(cl.eval_py(
            "local ctx = ...; local root = MenuUtil.CreateRootMenuDescription(); "
            "__MOCK.menu_modifiers.MENU_UNIT_PLAYER(UIParent, root, ctx); "
            "local o = { children = {} }; for i, d in ipairs(root.children) do "
            "o.children[i] = { text = d.text, kind = d.kind, children = {} } end; return o", ctx))]
    gina.set_target("Kaelthorn")
    assert "Add to Recruitment" in player_menu(gina, {"unit": "target"})
    gina.eval("ns.RecruitUI:AddFrom('Kaelthorn-Thunderstrike', 'whisper', 'target')")
    w.tick(1)
    p = person(gina, "Kaelthorn")
    assert p["c"] == "PALADIN" and p["lv"] and p["src"] == "whisper", p
    assert "Add to Recruitment" not in player_menu(gina, {"name": "Cora", "server": ""})     # a guild member
    cora.set_target("Kaelthorn")
    assert "Add to Recruitment" not in player_menu(cora, {"unit": "target"})                  # members: never
    w.assert_no_errors()


@case
def the_settings_card_is_the_gms_and_read_only_for_officers():
    w, c = guild()
    gina, bob, cora = c["Gina"], c["Bob"], c["Cora"]
    visible = "return ns.SettingsUI:CardVisible('recruit') and true or false"
    for x in (gina, bob):
        x.slash("/dz settings")
        w.tick(0.5)
        x.eval("ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('recruit')")
        w.tick(0.5)
        assert x.eval(visible) is True, x.name
    cora.slash("/dz settings")
    w.tick(0.5)
    assert cora.eval(visible) is False
    assert gina.find_text("You set these as Guild Master.", True, True)
    assert bob.find_text("Set by the Guild Master.", True, True)
    assert bob.eval("local s = ns.SettingsUI.rec; for _, r in ipairs(s.ruleRows) do if not r.readOnly then return false end end "
                    "return true") is True
    gina.eval("ns.Guild:SetRecruitRules({ q = 30 })")
    w.tick(5)
    assert bob.eval_py("return ns.Guild:GetRecruitRules().q") == 30
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
