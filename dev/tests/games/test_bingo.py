"""Games hub + Council Bingo on the real addon.

Covers: pure card logic (deterministic per seed + player, free centre, 12 lines), the hub registry and tab,
only the leader / an assistant can start, the host's hits syncing to every raider, non-hosts never detecting on
their own, a forged BG from a plain raider ignored, the first bingo announced once, /reload resuming the game via
BGQ, that Bingo never reacts to loot / council traffic, who set a square off, and the card UI (stamps, the line's
thread, the slam, the dauber). The detection itself: test_bingo_detect.py; the set, dealing, points, Fated, the
Codex and the moments: test_bingo_cards.py.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_bingo.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client, printed_since, strip_codes  # noqa: E402

REALM = "Thunderstrike"
GROUP_PLAYER = 0x400 + 0x4      # TYPE_PLAYER | AFFILIATION_RAID
GROUP_PET = 0x1000 + 0x4


def K(name):
    return "%s-%s" % (name, REALM)


def raid(names=("Lee", "Rita", "Sam", "Bob"), leader="Lee", assistants=(), extra=()):
    w = World()
    c = {}
    for n in names:
        c[n] = Client(w, n, guild_rank=3)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.make_raid(list(c.values()), leader=c[leader], assistants=[c[a] for a in assistants], extra_members=list(extra))
    w.tick(5)
    return w, c


def hits(cl):
    return cl.eval_py("local g = ns.Bingo:GetGame(); if not g then return {} end; "
                      "local t = {}; for id in pairs(g.hits) do t[#t+1] = id end; table.sort(t); return t") or []


def cleu(cl, sub, src=GROUP_PLAYER, dst=GROUP_PLAYER, *params):
    args = [0, sub, False, "src", "Src", src, 0, "dst", "Dst", dst, 0] + list(params)
    cl._call("combat_log", *args)


def cleu_g(cl, sub, src_guid, src, dst_guid, dst, *params):
    """cleu() with explicit source / destination GUIDs."""
    args = [0, sub, False, src_guid, "Src", src, 0, dst_guid, "Dst", dst, 0] + list(params)
    cl._call("combat_log", *args)


def start(w, c, host="Lee"):
    c[host].slash("/dz bingo start")
    w.tick(2)
    return c[host]


def said(c, n0):
    return [strip_codes(l) for l in printed_since(c, n0)]


# -- pure card logic -------------------------------------------------------------------------------------------------

@case
def card_is_deterministic_per_seed_and_player():
    w, c = solo("Alice", tick=2)
    a1 = c.eval_py("return ns.BingoCard.Deal('s1', 'Alice-X', ns.BingoSquares:Core())")
    a2 = c.eval_py("return ns.BingoCard.Deal('s1', 'Alice-X', ns.BingoSquares:Core())")
    b = c.eval_py("return ns.BingoCard.Deal('s1', 'Bob-X', ns.BingoSquares:Core())")
    a3 = c.eval_py("return ns.BingoCard.Deal('s2', 'Alice-X', ns.BingoSquares:Core())")
    assert a1 == a2 and a1 != b and a1 != a3
    assert len(a1) == 25 and a1[12] == "FREE"
    assert len(set(a1)) == 25, "no square twice on one card"
    assert set(a1) != set(b), "the pool is big enough that cards differ in content, not just order"
    no_errors(w)


@case
def score_counts_lines_and_the_free_centre():
    w, c = solo("Alice", tick=2)
    lines, marked = c.eval("local card = ns.BingoCard.Deal('s', 'A', ns.BingoSquares:Core()); "
                           "local lines, marked = ns.BingoCard.Score(card, {}); return lines, marked")
    assert (lines, marked) == (0, 1)
    # mark the middle row (cells 11-15): one line
    lines, marked = c.eval("local card = ns.BingoCard.Deal('s', 'A', ns.BingoSquares:Core()); local h = {}; "
                           "for i = 11, 15 do h[card[i]] = 1 end; local l, m = ns.BingoCard.Score(card, h); return l, m")
    assert (lines, marked) == (1, 5)
    # full card: 12 lines
    lines, marked = c.eval("local card = ns.BingoCard.Deal('s', 'A', ns.BingoSquares:Core()); local h = {}; "
                           "for i = 1, 25 do h[card[i]] = 1 end; local l, m = ns.BingoCard.Score(card, h); return l, m")
    assert (lines, marked) == (12, 25)
    assert c.eval("return #ns.BingoSquares.list >= 24")
    no_errors(w)


# -- hub ---------------------------------------------------------------------------------------------------------------

@case
def hub_lists_bingo_and_play_opens_the_tab():
    w, c = solo("Alice", tick=2)
    assert c.eval("return ns.Games:Get('bingo') ~= nil")
    c.slash("/dz play bingo")
    w.tick(0.2)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "games"
    assert c.eval("return ns.Games:SubmitScore('bingo', 7)") is True
    assert c.eval("return ns.Games:SubmitScore('bingo', 3)") is False
    assert c.eval("return ns.Games:GetData('bingo').best") == 7
    no_errors(w)


@case
def solo_practice_game_marks_own_squares():
    w, c = solo("Alice", tick=2)
    c.slash("/dz bingo start")
    w.tick(0.5)
    assert c.eval("return ns.Bingo:IsActive() and ns.Bingo:IsHost()")
    w.player_roll("Alice", value=1)
    w.tick(1)
    assert "roll_1" in hits(c)
    no_errors(w)


# -- raid play -----------------------------------------------------------------------------------------------------

@case
def only_leader_or_assistant_can_start():
    w, c = raid(assistants=("Rita",))
    n0 = len(c["Sam"].printed)
    c["Sam"].slash("/dz bingo start")
    w.tick(2)
    assert not c["Sam"].eval("return ns.Bingo:IsActive()")
    assert any("only the raid leader" in l for l in said(c["Sam"], n0))
    c["Rita"].slash("/dz bingo start")
    w.tick(2)
    for n in ("Lee", "Rita", "Sam", "Bob"):
        assert c[n].eval("return ns.Bingo:IsActive()"), n
        assert c[n].eval("return ns.Bingo:GetGame().host") == K("Rita"), n
    no_errors(w)


@case
def host_detects_and_everyone_sees_the_hits():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    # trash death (host only sees it: detection runs on the host alone)
    cleu(c["Lee"], "UNIT_DIED")
    cleu(c["Lee"], "UNIT_DIED", 0, GROUP_PET)
    cleu(c["Lee"], "ENVIRONMENTAL_DAMAGE", 0, GROUP_PLAYER, "Falling", 500)
    cleu(c["Lee"], "SPELL_CAST_SUCCESS", GROUP_PLAYER, 0, 32182, "Heroism", 1)
    cleu(c["Lee"], "SPELL_DAMAGE", GROUP_PLAYER, 0, 133, "Fireball", 4, 9000, 0, 4, 0, 0, 0, True)
    w.player_roll("Sam", value=1)
    w.tick(2)
    expected = {"death_trash", "pet_death", "fall", "lust", "big_crit", "roll_1"}
    for n in ("Lee", "Rita", "Sam", "Bob"):
        assert expected <= set(hits(c[n])), (n, hits(c[n]))
    no_errors(w)


@case
def non_host_never_detects_on_its_own():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    cleu(c["Sam"], "UNIT_DIED")
    c["Sam"].fire("CHAT_MSG_SYSTEM", "Sam rolls 1 (1-100)")
    w.tick(2)
    assert hits(c["Lee"]) == [] and hits(c["Sam"]) == []
    no_errors(w)


@case
def forged_state_from_a_plain_raider_is_ignored():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    c["Sam"].eval("ns.Comm:Send({ t = 'BG', g = ns.Bingo:GetGame().id, h = { 'drown' } }, 'RAID')")
    c["Sam"].eval("ns.Comm:Send({ t = 'BG', g = 'fake', h = { 'drown' } }, 'RAID')")
    w.tick(2)
    assert "drown" not in hits(c["Bob"])
    assert c["Bob"].eval("return ns.Bingo:GetGame().host") == K("Lee")
    no_errors(w)


@case
def first_bingo_is_announced_once_and_counted():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    # the host marks Rita's whole middle row
    c["Lee"].eval("local card = ns.Bingo:GetCard(...); for i = 11, 15 do if card[i] ~= 'FREE' then ns.Bingo:Hit(card[i]) end end",
                  K("Rita"))
    w.tick(2)
    for n in ("Lee", "Sam"):
        assert c[n].eval("return ns.Bingo:GetGame().winners[1]") == K("Rita"), n
        assert c[n].eval("return ns.Bingo:GetSeason()[...].firsts", K("Rita")) == 1
    c["Lee"].eval("ns.Bingo:Hit('drown')")
    w.tick(2)
    assert c["Sam"].eval("return ns.Bingo:GetSeason()[...].bingos", K("Rita")) == 1, "not counted twice"
    no_errors(w)


@case
def stop_ends_the_game_everywhere():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    c["Sam"].slash("/dz bingo stop")
    w.tick(1)
    assert c["Lee"].eval("return ns.Bingo:IsActive()"), "only the host can stop"
    c["Lee"].slash("/dz bingo stop")
    w.tick(2)
    for n in ("Lee", "Sam"):
        assert not c[n].eval("return ns.Bingo:IsActive()"), n
    no_errors(w)


@case
def reload_resumes_the_game():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    c["Lee"].eval("ns.Bingo:Hit('wipe')")
    w.tick(1)
    c["Sam"].relog()
    w.tick(1)
    c["Lee"].eval("ns.Bingo:Hit('lust')")
    w.tick(8)
    assert {"wipe", "lust"} <= set(hits(c["Sam"]))
    no_errors(w)


@case
def bingo_sends_on_the_game_channel():
    # Bingo's state (BG) and its question (BGQ) go out on the minigame prefix (CDLg) like the other games, never on
    # the council's control prefix (CDLc); receivers dispatch on the message type, so older clients still hear them.
    w, c = raid()
    spy = ("_G.__bgsent = {} local send = ns.Comm.Send "
           "ns.Comm.Send = function(self, msg, dist, target, class) "
           "if type(msg) == 'table' and (msg.t == 'BG' or msg.t == 'BGQ') then "
           "table.insert(_G.__bgsent, msg.t .. '=' .. tostring(class)) end "
           "return send(self, msg, dist, target, class) end")
    for n in ("Lee", "Sam"):
        c[n].eval(spy)
    log0 = len(w.addon_log)
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    c["Lee"].eval("ns.Bingo:Hit('wipe')")
    w.tick(11)      # (a question at most every 10 s: Sam may have asked when the raid formed)
    c["Sam"].eval("_G.__bgsent = {} ns.Bingo:RequestState()")
    w.tick(3)
    lee = c["Lee"].eval_py("return _G.__bgsent")
    sam = c["Sam"].eval_py("return _G.__bgsent")
    assert lee and all(x == "BG=game" for x in lee), lee
    assert sam == ["BGQ=game"], sam
    assert any(e["prefix"] == "CDLg" for e in w.addon_log[log0:] if e["sender"] == c["Lee"].full_name)
    assert "wipe" in hits(c["Sam"])
    no_errors(w)


@case
def bingo_ignores_loot_and_council_messages():
    w, c = raid()
    c["Lee"].slash("/dz bingo start")
    w.tick(2)
    for msg in ("DROP", "LEDGER_UPDATED", "ROLL_UPDATED", "ROLL_STARTED"):
        c["Lee"].eval("ns:Fire(...)", msg)
    w.tick(2)
    assert hits(c["Lee"]) == []
    no_errors(w)


# -- who set it off, and the card UI ----------------------------------------------------------------------------------

@case
def who_set_it_off_is_synced_to_everyone():
    w, c = raid()
    lee = start(w, c)
    cleu_g(lee, "SPELL_CAST_SUCCESS", c["Rita"].guid, GROUP_PLAYER, "", 0, 2825, "Bloodlust", 1)
    w.player_roll("Sam", value=1)
    lee.fire("ENCOUNTER_START", 652, "Attumen", 3, 4)
    lee.fire("ENCOUNTER_END", 652, "Attumen", 3, 4, 0)
    lee.eval("ns.Bingo:Hit('drown')")                   # no name: fine
    w.tick(2)
    for n in ("Lee", "Bob"):
        assert c[n].eval("return ns.Bingo:GetWho('lust')") == "Src", n      # cleu_g names the source "Src"
        assert c[n].eval("return ns.Bingo:GetWho('roll_1')") == "Sam", n
        assert c[n].eval("return ns.Bingo:GetWho('wipe')") == "Attumen", n
        assert c[n].eval("return ns.Bingo:GetWho('drown')") is None, n
    feed = c["Bob"].eval_py("local t = {}; for _, e in ipairs(ns.Bingo:GetFeed()) do t[#t+1] = e.id end; return t")
    assert set(feed) >= {"lust", "roll_1", "wipe", "drown"}, feed
    # a /reload gets the names back from the host
    c["Bob"].relog()
    w.tick(8)
    assert c["Bob"].eval("return ns.Bingo:GetWho('roll_1')") == "Sam"
    no_errors(w)


@case
def a_raider_cannot_forge_who_names():
    w, c = raid()
    start(w, c)
    c["Lee"].eval("ns.Bingo:Hit('wipe', 'Lee')")
    w.tick(2)
    c["Sam"].eval("ns.Comm:Send({ t = 'BG', g = ns.Bingo:GetGame().id, h = { 'wipe' }, w = { wipe = 'Sam' } }, 'RAID')")
    w.tick(2)
    assert c["Bob"].eval("return ns.Bingo:GetWho('wipe')") == "Lee"
    no_errors(w)


WS = "local W = ns.BingoUI:GetWidgets(); "


def open_card(w, cl):
    cl.slash("/dz play bingo")
    w.tick(0.3)
    assert cl.eval(WS + "return W.panel:IsVisible()")


@case
def card_ui_stamps_lines_and_slam():
    w, c = raid()
    lee = start(w, c)
    rita = c["Rita"]
    open_card(w, rita)
    # Rita's middle row (the centre is free), one square at a time
    lee.eval("local card = ns.Bingo:GetCard(...); ns.Bingo:Hit(card[11], 'Sam'); ns.Bingo:Hit(card[12])", K("Rita"))
    w.tick(2)
    assert rita.eval(WS + "return W.cells[11].stamp:IsShown()")
    tip = rita.eval_py(WS + "local t = {}; for i, l in ipairs(W.cells[11].tip) do t[i] = type(l) == 'table' and l[1] or l end; return t")
    tip = list(tip.values()) if isinstance(tip, dict) else tip
    assert any("by Sam" in str(l) for l in tip), tip
    assert not rita.eval(WS + "return W.cells[14].stamp:IsShown()")
    lee.eval("local card = ns.Bingo:GetCard(...); ns.Bingo:Hit(card[14])", K("Rita"))
    w.tick(2)
    assert rita.eval(WS + "return W.cells[15].pulse:IsShown()"), "one away pulses"
    assert "one away" in strip_codes(rita.eval(WS + "return W.status:GetText()"))
    assert not rita.eval(WS + "return W.slam:IsShown()")
    lee.eval("local card = ns.Bingo:GetCard(...); ns.Bingo:Hit(card[15])", K("Rita"))
    w.tick(0.5)
    assert rita.eval(WS + "return W.slam:IsShown()"), "BINGO! slam"
    assert "BINGO" in rita.eval(WS + "return W.slam.text:GetText()")
    assert not rita.eval(WS + "return W.cells[15].pulse:IsShown()")
    # the row's gold thread: its four links (row 3 is line 5), nothing else
    shown = rita.eval_py(WS + "local t = {}; for li, segs in ipairs(W.threads) do for k, s in ipairs(segs) do "
                         "if s.core:IsShown() then t[#t+1] = li * 10 + k end end end; return t")
    shown = sorted(shown.values() if isinstance(shown, dict) else shown)
    assert shown == [51, 52, 53, 54], shown
    w.tick(4)
    assert not rita.eval(WS + "return W.slam:IsShown()"), "the slam fades out"
    # the race lists Rita first with her bingo; the feed has the four hits
    assert "Rita" in strip_codes(rita.eval(WS + "return W.race[1].left:GetText()"))
    assert rita.eval(WS + "return W.race[1].pill:IsShown()"), "the BINGO pill"
    assert rita.eval(WS + "local n = 0; for _, r in ipairs(W.feed) do if r:IsShown() then n = n + 1 end end; return n") == 4
    # re-opening doesn't slam again
    rita.eval("ns.MainFrame:Close()")
    w.tick(0.2)
    open_card(w, rita)
    assert not rita.eval(WS + "return W.slam:IsShown()")
    no_errors(w)


@case
def dauber_choice_changes_the_stamp_and_the_card_fits():
    w, c = solo("Alice", tick=2)
    c.slash("/dz bingo start")
    w.tick(0.5)
    open_card(w, c)
    c.eval("local card = ns.Bingo:GetMyCard(); ns.Bingo:Hit(card[1])")
    w.tick(0.5)
    assert str(c.eval(WS + "return W.cells[1].stamp:GetTexture()")).endswith("_1")
    c.eval(WS + "W.dauber[8]:Click()")
    w.tick(0.2)
    assert str(c.eval(WS + "return W.cells[1].stamp:GetTexture()")).endswith("_8")
    assert c.eval("return ns.Games:GetData('bingo').dauber") == 8
    # the card, the right column and the header fill the hub's ~786 x 518 stage without spilling (the mock does no
    # layout, so the panel lays itself out for that fallback size: check the declared sizes)
    wid, hei = c.eval(WS + "return W.card:GetWidth(), W.card:GetHeight()")
    sw = c.eval(WS + "return W.side:GetWidth()")
    hh = c.eval(WS + "return W.hero:GetHeight()")
    assert 10 + wid + 8 + sw + 10 <= 786 and hh + 10 + hei + 10 <= 518, (wid, hei, sw, hh)
    assert wid >= 480 and hei >= 360, (wid, hei)                     # (the card uses the room it has)
    cw, ch = c.eval(WS + "return W.cells[1]:GetWidth(), W.cells[1]:GetHeight()")
    assert cw >= 90 and ch >= 70, (cw, ch)
    no_errors(w)


if __name__ == "__main__":
    run_all("games / Council Bingo")
