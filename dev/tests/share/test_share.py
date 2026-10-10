"""Share links in chat (UI/Share.lua, UI/ShareWindow.lua): a link goes out as plain text
"[DisasterZone: <label> #<ref>]", every DisasterZone client shows it as a clickable "addon:DisasterZone:<ref>" link
(icon + label from its own data), a click opens the place, shift-click puts it in the chat box, hovering explains it.
The Share window posts to Guild / Officer / Raid / Party / Say or whispers an online guild member.

Run: luaenv\\Scripts\\python.exe tests\\share\\test_share.py [-k name]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "strategy"))

from st_common import world, K, DAY, now, create, signup, team, COUNCIL  # noqa: E402
from _common import case, run_all, printed_since, strip_codes, install_helpers, tt_lines, Client, menu_pick  # noqa: E402

LINK = "addon:DisasterZone:"

# Lua: find(frame, tipTitle) -> the shown share buttons under a frame with that tooltip title
FIND_SHARE = """
local function find(f, title, out)
  out = out or {}
  for _, ch in ipairs({ f:GetChildren() }) do
    if ch.tipTitle == title and ch:IsShown() then out[#out + 1] = ch end
    find(ch, title, out)
  end
  return out
end
"""


def save_strategy(cl, name, boss=None):
    res = cl.eval_py("local src, n, b = ...; local d = (loadstring(src))(); d.n = n; if b then d.b = b end; "
                     "local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", COUNCIL, name, boss)
    assert res["ok"] is True, res
    return res["r"]


def when(cl, occ):
    """The raid's start as a link label writes it on this client ("Thu 9 Oct 20:00")."""
    return cl.eval("local t = ns.RaidPlan:GetRaid(...).t; "
                   "return ('%s %d %s %s'):format(date('%a', t), tonumber(date('%d', t)), date('%b', t), "
                   "date('%H:%M', t))", occ)


def last_chat(w, chat_type=None):
    for e in reversed(w.chat_log):
        if chat_type is None or e["chat_type"] == chat_type:
            return e
    return None


def shown(cl, event):
    """The lines of a chat event as this client's chat frames show them."""
    return [e["text"] for e in cl.chat_shown if e["event"] == event]


def window(cl):
    return "ns.ShareWindow:GetWindow()"


def open_share(cl, ref):
    assert cl.eval("return ns.ShareWindow:Open(...)", ref) is True
    return cl.eval("return ns.ShareWindow:GetWindow()")


def raid_world():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + DAY, no="Bring pots")
    w.tick(2)
    return w, c, occ


# ------------------------------------------------------------------------------------------------------------------
@case
def a_raid_link_goes_out_as_text_and_comes_in_as_a_link():
    w, c, occ = raid_world()
    bob, rita = c["Bob"], c["Rita"]
    win = open_share(bob, "raid:" + occ)
    assert bob.eval("return ns.ShareWindow:GetWindow():IsShown()") is True
    bob.type_text(bob.eval("return ns.ShareWindow:GetWindow().msg"), "Sign up please!")
    bob.click(bob.eval("return ns.ShareWindow:GetWindow().channels.GUILD"))
    w.tick(1)
    e = last_chat(w, "GUILD")
    label = "Karazhan · " + when(bob, occ)
    assert e["text"] == "Sign up please! [DisasterZone: %s #raid:%s]" % (label, occ), e
    assert len(e["text"].encode("utf-8")) <= 255
    assert bob.eval("return ns.ShareWindow:GetWindow():IsShown()") is False     # sent: the window closes
    # Rita (DisasterZone) sees a link with an icon; the label is her own (her local time)
    line = shown(rita, "CHAT_MSG_GUILD")[-1]
    assert line.startswith("Sign up please! |TInterface\\Icons\\INV_Misc_Head_Dragon_01:"), line
    assert ("|cffff8000|H%sraid:%s|h[Karazhan · %s]|h|r" % (LINK, occ, when(rita, occ))) in line, line
    # the sender's own echo is a link too
    assert ("|H%sraid:%s|h" % (LINK, occ)) in shown(bob, "CHAT_MSG_GUILD")[-1]
    # a plain guild line is left as it is
    bob.eval("C_ChatInfo.SendChatMessage('hello guild', 'GUILD')")
    w.tick(1)
    assert shown(rita, "CHAT_MSG_GUILD")[-1] == "hello guild"
    w.assert_no_errors()


@case
def clicking_a_raid_link_opens_the_raid_and_its_tab():
    w, c, occ = raid_world()
    rita = c["Rita"]
    rita.click_link(LINK + "raid:" + occ)
    w.tick(0.5)
    assert rita.eval("return ns.MainFrame:GetSelectedTab()") == "raids"
    assert rita.eval("return ns.RaidsUI:GetView()") == "upcoming"
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    assert rita.eval("return ns.RaidPlanUI:GetDetailTab()") in (None, "signups")
    rita.eval("ns.MainFrame:Close()")
    rita.click_link(LINK + "raid:" + occ + ":groups")
    w.tick(0.5)
    assert rita.eval("return ns.RaidPlanUI:GetDetailTab()") == "groups"
    assert rita.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    w.assert_no_errors()


@case
def shift_click_puts_the_link_in_the_chat_box_and_right_click_shares_it_on():
    w, c, occ = raid_world()
    rita = c["Rita"]
    rita.set_modifiers(shift=True)
    rita.click_link(LINK + "raid:" + occ, "|cffff8000|H%sraid:%s|h[Old name]|h|r" % (LINK, occ))
    rita.set_modifiers()
    assert rita.opened_chat == "[DisasterZone: Karazhan · %s #raid:%s]" % (when(rita, occ), occ), rita.opened_chat
    assert rita.eval("return ns.MainFrame:IsShown()") is False
    rita.click_link(LINK + "raid:" + occ, "", "RightButton")
    assert rita.eval("return ns.ShareWindow:GetRef()") == "raid:" + occ
    w.assert_no_errors()


@case
def hovering_a_link_tells_what_it_is():
    w, c, occ = raid_world()
    rita, lee = c["Rita"], c["Lee"]
    signup(lee, occ, "A", 3)
    w.tick(2)
    install_helpers(rita)
    rita.hover_link(LINK + "raid:" + occ)
    lines = [strip_codes(l) for l, _ in tt_lines(rita)]
    assert lines[0] == "Karazhan (10)", lines
    assert any("1/10 accepted" in l for l in lines), lines
    assert "You haven't answered yet" in lines and "Bring pots" in lines, lines
    assert "Click to open in DisasterZone" in lines, lines
    rita.leave_link()
    assert rita.eval("return GameTooltip:IsShown()") is False
    # a member: class, rank, online
    rita.hover_link(LINK + "member:Lee")
    lines = [strip_codes(l) for l, _ in tt_lines(rita)]
    assert lines[0] == "Lee" and "Online" in lines, lines
    assert any("Level" in l and "Warrior" in l for l in lines), lines
    # something that hasn't reached me
    rita.hover_link(LINK + "raid:ffffffffffff", "|H%sraid:ffffffffffff|h[Gruul · Sun 1 Nov]|h" % LINK)
    lines = [strip_codes(l) for l, _ in tt_lines(rita)]
    assert lines[0] == "Gruul · Sun 1 Nov" and any("hasn't reached you" in l for l in lines), lines
    w.assert_no_errors()


@case
def member_game_strategy_page_and_version_links_open_their_place():
    w, c, occ = raid_world()
    bob, rita = c["Bob"], c["Rita"]
    sid = save_strategy(bob, "Teron farm", "BlackTemple:Teron")
    w.tick(3)
    rita.click_link(LINK + "member:Lee")
    w.tick(0.3)
    assert rita.eval("return ns.MainFrame:GetSelectedTab()") == "members"
    assert rita.eval("return ns.MembersUI:GetState().member") == K("Lee")
    rita.click_link(LINK + "game:bingo")
    w.tick(0.3)
    assert rita.eval("return ns.MainFrame:GetSelectedTab()") == "games"
    assert rita.eval("return ns.GamesUI:GetSelected()") == "bingo"
    rita.click_link(LINK + "teams")
    w.tick(0.3)
    assert rita.eval("return ns.RaidsUI:GetView()") == "teams"
    rita.click_link(LINK + "recipes")
    w.tick(0.3)
    assert rita.eval("return ns.MembersUI:GetMode()") == "recipes"
    rita.click_link(LINK + "ver:1.2.0")
    w.tick(0.3)
    assert rita.eval("return ns.MainFrame:GetSelectedTab()") == "changelog"
    assert rita.eval("return ns.ChangelogUI:GetSelected()") == "1.2.0"
    rita.click_link(LINK + "strat:" + sid)
    w.tick(0.3)
    st = rita.eval_py("local st = ns.StrategyBoard:GetState(); return { id = st.strat and st.strat.id, mode = st.mode }")
    assert st == {"id": sid, "mode": "view"}, st
    assert rita.eval("return ns.StrategyBoard:GetWindow():IsShown()") is True
    w.assert_no_errors()


@case
def links_to_what_is_not_here_say_so():
    w, c, occ = raid_world()
    rita, bob = c["Rita"], c["Bob"]
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "raid:ffffffffffff")
    assert any("That raid isn't here" in l for l in printed_since(rita, n0))
    assert rita.eval("return ns.RaidsUI:GetView()") == "upcoming"     # the page it would be on
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "council")
    assert any("The Council tab is for the loot council." in l for l in printed_since(rita, n0))
    assert rita.eval("return ns.MainFrame:GetSelectedTab()") != "council"
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "raidlog")
    assert any("The Raid log is for" in l for l in printed_since(rita, n0)), printed_since(rita, n0)
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "member:Nobody")
    assert any("Nobody is not in the guild." in l for l in printed_since(rita, n0))
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "ver:9.9.9")
    assert any("Version 9.9.9 isn't in your DisasterZone yet" in l for l in printed_since(rita, n0))
    # a kind of link from a newer version stays plain text; clicking one (if ever made) explains
    out = rita.eval("return ns.Share:Rewrite(...)", "look [DisasterZone: Thing #widget:12]")
    assert out is None
    n0 = len(rita.chat_frame)
    rita.click_link(LINK + "widget:12")
    assert any("newer DisasterZone" in l for l in printed_since(rita, n0))
    # the council's page opens for the council
    bob.click_link(LINK + "council")
    assert bob.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    w.assert_no_errors()


@case
def labels_come_from_my_data_and_are_cleaned():
    w, c, occ = raid_world()
    rita, bob = c["Rita"], c["Bob"]
    # a made-up label for a raid I have: my own label wins
    out = rita.eval("return ns.Share:Rewrite(...)", "[DisasterZone: Free gold #raid:%s]" % occ)
    assert "Free gold" not in out and ("[Karazhan · %s]" % when(rita, occ)) in out, out
    # one I don't have: the sent label, as text
    out = rita.eval("return ns.Share:Rewrite(...)", "[DisasterZone: Gruul · Sun 1 Nov #raid:abcdef123456]")
    assert "|h[Gruul · Sun 1 Nov]|h" in out, out
    # a member in their class colour, the brackets orange around it
    out = rita.eval("return ns.Share:Rewrite(...)", "[DisasterZone: Lee #member:Lee]")
    assert re.search(r"\|h\[\|cff[0-9a-f]{6}Lee\|r\|cffff8000\]\|h\|r", out), out
    assert "UI-Classes-Circles" in out
    # two links in one line, text around them kept
    out = rita.eval("return ns.Share:Rewrite(...)", "a [DisasterZone: Games #games] b [DisasterZone: Home #home] c")
    assert out.startswith("a ") and " b " in out and out.endswith(" c"), out
    assert out.count("|H" + LINK) == 2
    # names that can't travel: brackets go, a long one is cut, colours and bars go from a label passed on
    sid = save_strategy(bob, "Teron [best] kite", "BlackTemple:Teron")
    w.tick(3)
    token = bob.eval("return ns.Share:Text(...)", "strat:" + sid)
    assert token == "[DisasterZone: Teron Gorefiend: Teron best kite #strat:%s]" % sid, token
    assert rita.eval("return ns.Share:Parse(...)[1].ref", token) == "strat:" + sid
    token = bob.eval("return ns.Share:Text(...)", "raid:abcdef123456", "|cffff0000Gruul|r " + "é" * 80)
    label = token[len("[DisasterZone: "):token.index(" #raid:")]
    assert label.startswith("Gruul éé") and label.endswith("...") and len(label.encode("utf-8")) <= 70, label
    assert "|" not in token and token.count("[") == 1 and token.count("]") == 1, token
    # a long message is cut to fit one chat line
    bob.eval("local ref = ...; ns.Share:Send(ref, 'GUILD', nil, ('Ünïcode '):rep(40))", "raid:" + occ)
    w.tick(1)
    e = last_chat(w, "GUILD")
    assert len(e["text"].encode("utf-8")) <= 255 and e["text"].endswith("#raid:%s]" % occ), e
    e["text"].encode("utf-8").decode("utf-8")      # no character cut in half
    w.assert_no_errors()


@case
def zone_channels_are_left_alone():
    w, c, occ = raid_world()
    rita = c["Rita"]
    token = "[DisasterZone: Home #home]"
    res = rita.eval_py("local msg = ...; local f = ChatFrame_GetMessageEventFilters('CHAT_MSG_CHANNEL')[1]; "
                       "local a, b = f(ChatFrame1, 'CHAT_MSG_CHANNEL', msg, 'Zed', '', '2. Trade', '', '', 2, 2); "
                       "local c2, d = f(ChatFrame1, 'CHAT_MSG_CHANNEL', msg, 'Zed', '', '5. cdraid', '', '', 0, 5); "
                       "return { trade = b or false, own = d or false }", token)
    assert res["trade"] is False, res
    assert ("|H%shome|h" % LINK) in res["own"], res
    w.assert_no_errors()


@case
def the_window_offers_the_chats_that_apply():
    w, c, occ = raid_world()
    rita, gina, bob = c["Rita"], c["Gina"], c["Bob"]

    def chans(cl):
        return cl.eval_py("local w = ns.ShareWindow:GetWindow(); local out = {}; "
                          "for _, k in ipairs({ 'GUILD', 'OFFICER', 'RAID', 'PARTY', 'SAY' }) do local b = w.channels[k]; "
                          "out[k] = b:IsShown() and ((b:IsEnabled() and 'on' or 'off') .. (b.kind == 'primary' and '*' or '')) "
                          "or 'hidden' end; return out")
    open_share(rita, "raid:" + occ)
    assert chans(rita) == {"GUILD": "on*", "OFFICER": "hidden", "RAID": "off", "PARTY": "off", "SAY": "on"}, chans(rita)
    rita.eval("ns.ShareWindow:Close()")
    open_share(gina, "raid:" + occ)
    assert chans(gina)["OFFICER"] == "on"
    w.make_raid([bob, rita, c["Lee"]], leader=bob)
    w.tick(1)
    open_share(rita, "raid:" + occ)
    assert chans(rita) == {"GUILD": "on", "OFFICER": "hidden", "RAID": "on*", "PARTY": "on", "SAY": "on"}, chans(rita)
    # Enter in the message posts in the gold one (the raid)
    rita.type_text(rita.eval("return ns.ShareWindow:GetWindow().msg"), "Read this", enter=True)
    w.tick(1)
    e = last_chat(w)
    assert e["chat_type"] == "RAID" and e["text"].startswith("Read this [DisasterZone: Karazhan"), e
    assert ("|H%sraid:%s|h" % (LINK, occ)) in (shown(bob, "CHAT_MSG_RAID_LEADER") + shown(bob, "CHAT_MSG_RAID"))[-1]
    # a disabled chat explains itself and sends nothing
    rita.eval("ns.ShareWindow:Close()")
    open_share(gina, "raids")
    n = len(w.chat_log)
    assert gina.eval("return ns.ShareWindow:Send('RAID')") is False
    assert len(w.chat_log) == n
    w.assert_no_errors()


@case
def whisper_a_guild_member_from_the_window():
    w, c, occ = raid_world()
    rita, lee = c["Rita"], c["Lee"]
    open_share(rita, "member:Lee")

    def rows():
        return rita.eval_py("local out = {}; for _, d in ipairs(ns.ShareWindow:GetWindow().list:GetData()) do "
                            "out[#out + 1] = d.outsider and ('+' .. d.name) or d.name end; return out") or []
    assert rows() == ["Bob", "Gina", "Lee", "Sam"], rows()          # online, not me, by name
    rita.type_text(rita.eval("return ns.ShareWindow:GetWindow().search"), "le")
    assert rows() == ["Lee"], rows()
    rita.type_text(rita.eval("return ns.ShareWindow:GetWindow().search"), "zed")
    assert rows() == ["+Zed"], rows()                                 # not in the guild: whisper them anyway
    rita.type_text(rita.eval("return ns.ShareWindow:GetWindow().search"), "lee")
    rita.eval("ns.ShareWindow:GetWindow().msg:SetText('your card')")
    rita.eval("ns.ShareWindow:GetWindow().list.box:ForEachFrame(function(row) row:Click() end)")
    w.tick(1)
    e = last_chat(w, "WHISPER")
    assert e["target"] == "Lee" and e["text"] == "your card [DisasterZone: Lee #member:Lee]", e
    assert ("|H%smember:Lee|h" % LINK) in shown(lee, "CHAT_MSG_WHISPER")[-1]
    assert ("|H%smember:Lee|h" % LINK) in shown(rita, "CHAT_MSG_WHISPER_INFORM")[-1]
    assert rita.eval("return ns.ShareWindow:GetWindow():IsShown()") is False
    # Put in chat box: the message and the link, for the chat box
    open_share(rita, "games")
    rita.eval("ns.ShareWindow:GetWindow().msg:SetText('play with us')")
    rita.click(rita.eval("return ns.ShareWindow:GetWindow().chatBtn"))
    assert rita.opened_chat == "play with us [DisasterZone: Games #games]", rita.opened_chat
    w.assert_no_errors()


@case
def share_icons_on_raids_members_strategies_boards_and_games():
    w, c, occ = raid_world()
    rita, bob = c["Rita"], c["Bob"]
    sid = save_strategy(bob, "Teron farm", "BlackTemple:Teron")
    w.tick(3)
    # a raid (everyone): the navigation strip's Share icon, while its page is open
    rita.slash("/dz raids")
    w.tick(0.5)
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    btn = "ns.MainFrame:GetShareButton()"
    assert rita.eval("return %s:IsShown()" % btn) is True
    rita.eval("ns.RaidPlanUI:SetDetailTab('assign')")
    rita.click(rita.eval("return " + btn))
    assert rita.eval("return ns.ShareWindow:GetRef()") == "raid:%s:assign" % occ
    rita.eval("ns.ShareWindow:Close()")
    # shift-click: straight into the chat box
    rita.set_modifiers(shift=True)
    rita.click(rita.eval("return " + btn))
    rita.set_modifiers()
    assert rita.opened_chat == "[DisasterZone: Karazhan · %s · Assignments #raid:%s:assign]" % (when(rita, occ), occ)
    assert rita.eval("return ns.ShareWindow:GetRef()") is None
    # a member's card and a recipe
    rita.eval("ns.MainFrame:Open('members'); ns.MembersUI:ShowMember(...)", K("Lee"))
    w.tick(0.3)
    share = "ns.MembersUI:GetPanel().right.share"
    assert rita.eval("return %s:IsShown()" % share) is True
    rita.click(rita.eval("return " + share))
    assert rita.eval("return ns.ShareWindow:GetRef()") == "member:Lee"
    rita.eval("ns.ShareWindow:Close()")
    # the strategy library's rows and the board
    rita.eval("ns.MainFrame:Open('raids'); ns.RaidsUI:SetView('strategies')")
    w.tick(0.3)
    # (a card's Share sits in its More menu)
    assert rita.eval("local out; ns.RaidsUI:GetPanel().strategies.detail.list.box:ForEachFrame(function(row) "
                     "local d = row.__cdlData; if d and d.s and d.s.n == 'Teron farm' then row.more:Click(); "
                     "out = true end end); return out") is True
    menu_pick(rita, "Share")
    got = rita.eval("return ns.ShareWindow:GetRef()")
    assert got == "strat:" + sid, got
    rita.eval("ns.ShareWindow:Close(); ns.StrategyBoard:OpenStrategy(...)", sid)
    w.tick(0.3)
    assert rita.eval("return ns.StrategyBoard:GetWindow().shareBtn:IsShown()") is True
    rita.click(rita.eval("return ns.StrategyBoard:GetWindow().shareBtn"))
    assert rita.eval("return ns.ShareWindow:GetRef()") == "strat:" + sid
    rita.eval("ns.ShareWindow:Close(); ns.StrategyBoard:OpenRaid(...)", occ, "Karazhan:Attumen")
    w.tick(0.3)
    ref = rita.eval("return ns.StrategyBoard:GetWindow().shareBtn.getRef()")
    assert ref == "board:%s:Karazhan:Attumen" % occ, ref
    # the games: one in the strip over the open game (the carousel itself has none: the page's own share is "games")
    rita.eval("ns.ShareWindow:Close(); ns.MainFrame:Open('games')")
    w.tick(0.3)
    refs = []
    for gid in ("bingo", "trainer", "azeromon"):
        rita.eval("ns.GamesUI:Select(...)", gid)
        w.tick(0.3)
        refs += rita.eval_py(FIND_SHARE + "local out = {}; for _, b in ipairs(find(ns.MainFrame:GetFrame(), 'Share this game')) "
                             "do b:Click(); out[#out + 1] = ns.ShareWindow:GetRef(); ns.ShareWindow:Close() end; return out")
    assert refs == ["game:bingo", "game:trainer", "game:azeromon"], refs
    w.assert_no_errors()


@case
def the_nav_share_links_what_the_page_shows():
    w, c, occ = raid_world()
    rita, bob = c["Rita"], c["Bob"]
    cur = lambda cl: cl.eval("return ns.Share:CurrentRef()")  # noqa: E731
    rita.slash("/dz raids")
    w.tick(0.5)
    assert cur(rita) == "raids"                   # the board: the page; a raid's page: that raid
    rita.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    assert cur(rita) == "raid:" + occ
    rita.eval("ns.RaidsUI:SetView('teams')")
    assert cur(rita) == "teams"
    tid = team(bob, "Kara A", ["Rita", "Lee"])
    w.tick(2)
    rita.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    assert cur(rita) == "team:" + tid
    rita.eval("ns.RaidsUI:SetView('strategies')")
    assert cur(rita) == "strategies"
    rita.eval("ns.MainFrame:Open('members'); ns.MembersUI:ShowMember(...)", K("Sam"))
    assert cur(rita) == "member:Sam"
    rita.eval("ns.MainFrame:Open('games'); ns.GamesUI:Select('azeromon')")
    assert cur(rita) == "game:azeromon"
    rita.eval("ns.MainFrame:Open('mybis')")
    assert cur(rita) == "mybis"
    rita.eval("ns.MainFrame:Open('changelog')")
    assert cur(rita) == "ver:" + rita.eval("return ns.ChangelogUI:GetSelected()"), cur(rita)
    # the icon in the navigation strip opens the window for it
    rita.eval("ns.MainFrame:Open('members'); ns.MembersUI:ShowMember(...)", K("Sam"))
    nav = rita.eval_py("local out; for _, f in ipairs({ ns.MainFrame:GetFrame():GetChildren() }) do "
                       "if f.tipTitle == 'Share this page' then out = f end end; return out ~= nil")
    assert nav is True
    rita.eval("for _, f in ipairs({ ns.MainFrame:GetFrame():GetChildren() }) do "
              "if f.tipTitle == 'Share this page' then f:Click() end end")
    assert rita.eval("return ns.ShareWindow:GetRef()") == "member:Sam"
    # /dz share does the same
    rita.eval("ns.ShareWindow:Close(); ns.MainFrame:Open('games'); ns.GamesUI:Select('bingo')")
    rita.slash("/dz share")
    assert rita.eval("return ns.ShareWindow:GetRef()") == "game:bingo"
    w.assert_no_errors()


@case
def players_without_the_addon_read_plain_text():
    w, c, occ = raid_world()
    bob = c["Bob"]
    pug = Client(w, "Zed", class_file="MAGE")     # no guild, no DisasterZone
    w.tick(1)
    bob.eval("local ref = ...; ns.Share:Send(ref, 'SAY', nil, 'hi')", "raid:" + occ)
    w.tick(1)
    e = last_chat(w, "SAY")
    assert e["text"] == "hi [DisasterZone: Karazhan · %s #raid:%s]" % (when(bob, occ), occ), e
    assert "|" not in e["text"]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
