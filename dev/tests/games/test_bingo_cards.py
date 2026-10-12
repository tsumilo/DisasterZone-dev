"""Council Bingo, the 1.5 makeover: the card set, dealing, points, Fated, the Codex and how moments arrive.

Covers: the square set (qualities, raid pools of 10+), dealing a card like a pack (1 legendary, 2 epic, 4 rare,
7 uncommon, 10 common; up to 6 from the raid's pool, deterministic per seed + player + raid), the raid pool synced from
the host, points (quality + 10 a line), Fated (the host picks the best gap of everyone holding a legendary and every
client agrees), the Codex (what this character saw, games played), BINGO_MOMENT (once per new square, quiet when a game
is joined late), the toasts (epic for everyone, legendary when the card isn't open) and the takeover on the open card,
the Card / Codex switch on the hub's strip, and the card's squares (legendary edge, 1 AWAY, the gold thread).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_bingo_cards.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

REALM = "Thunderstrike"
DEAL = {"l": 1, "e": 2, "r": 4, "u": 7, "c": 10}


def K(name):
    return "%s-%s" % (name, REALM)


def raid(names=("Lee", "Rita", "Sam", "Bob"), leader="Lee"):
    w = World()
    c = {}
    for n in names:
        c[n] = Client(w, n, guild_rank=3)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.make_raid(list(c.values()), leader=c[leader])
    w.tick(5)
    return w, c


def start(w, c, host="Lee"):
    c[host].slash("/dz bingo start")
    w.tick(2)
    return c[host]


def mix(cl, card_lua):
    """{quality: count} of a card (FREE left out) dealt by the Lua expression card_lua."""
    return cl.eval_py("local card = " + card_lua + "; local t = {}; for _, id in ipairs(card) do "
                      "local sq = ns.BingoSquares:Get(id); if sq then t[sq.q] = (t[sq.q] or 0) + 1 end end; return t")


WS = "local W = ns.BingoUI:GetWidgets(); "


def open_card(w, cl):
    cl.slash("/dz play bingo")
    w.tick(0.3)
    assert cl.eval(WS + "return W.panel:IsVisible()")


# -- the set and the deal ------------------------------------------------------------------------------------------------

@case
def the_set_has_named_squares_and_a_pool_per_raid():
    w, c = solo("Alice", tick=2)
    bad = c.eval_py("local bad, seen = {}, {} "
                    "for _, sq in ipairs(ns.BingoSquares.list) do "
                    "  if seen[sq.id] then bad[#bad+1] = 'twice ' .. sq.id end seen[sq.id] = true "
                    "  if not ns.BingoSquares.QUALITY[sq.q] then bad[#bad+1] = 'quality ' .. sq.id end "
                    "  if type(sq.title) ~= 'string' or type(sq.text) ~= 'string' or type(sq.icon) ~= 'string' then "
                    "    bad[#bad+1] = 'fields ' .. sq.id end end return bad")
    assert bad == [] or bad == {}, bad
    core = c.eval_py("local t = {}; for _, sq in ipairs(ns.BingoSquares:Core()) do t[sq.q] = (t[sq.q] or 0) + 1 end; return t")
    for q, n in DEAL.items():
        assert core.get(q, 0) >= n, (q, core)
    assert sum(core.values()) == 48, core
    for raid_key in ("kara", "gruul", "mag", "ssc", "tk"):
        n = c.eval("return #ns.BingoSquares:Pool(...)", raid_key)
        assert n >= 10, (raid_key, n)
    # the old filler is gone: one roll square left
    rolls = c.eval_py("local t = {}; for _, sq in ipairs(ns.BingoSquares.list) do "
                      "if sq.id:find('^roll') or sq.id == 'odd_roll' then t[#t+1] = sq.id end end; return t")
    assert list(rolls.values() if isinstance(rolls, dict) else rolls) == ["roll_1"], rolls
    no_errors(w)


@case
def a_card_is_dealt_like_a_pack():
    w, c = solo("Alice", tick=2)
    deal = "ns.BingoCard.Deal('%s', '%s', ns.BingoSquares:Core(), nil)"
    a1 = c.eval_py("return " + deal % ("s1", "Alice-X"))
    a2 = c.eval_py("return " + deal % ("s1", "Alice-X"))
    b = c.eval_py("return " + deal % ("s1", "Bob-X"))
    a3 = c.eval_py("return " + deal % ("s2", "Alice-X"))
    assert a1 == a2 and a1 != b and a1 != a3
    assert len(a1) == 25 and a1[12] == "FREE"
    assert len(set(a1)) == 25, "no square twice on one card"
    for who in ("Alice-X", "Bob-X", "Cid-X", "Dee-X"):
        assert mix(c, deal % ("s1", who)) == DEAL, who
    no_errors(w)


@case
def a_raid_deals_up_to_six_from_its_pool_and_keeps_the_mix():
    w, c = solo("Alice", tick=2)
    for raid_key in ("kara", "ssc", "tk"):
        for who in ("Alice-X", "Bob-X", "Cid-X"):
            expr = "ns.BingoCard.Deal('s1', '%s', ns.BingoSquares:Core(), ns.BingoSquares:Pool('%s'))" % (who, raid_key)
            assert mix(c, expr) == DEAL, (raid_key, who)
            n = c.eval("local card = " + expr + "; local n = 0; for _, id in ipairs(card) do "
                       "local sq = ns.BingoSquares:Get(id); if sq and sq.raid == ... then n = n + 1 end end; return n", raid_key)
            assert 1 <= n <= 6, (raid_key, who, n)
    no_errors(w)


@case
def the_hosts_raid_pool_reaches_everyone():
    w, c = raid()
    lee = start(w, c)
    # the host was not in a raid at the start; entering SSC before anything happened deals from its pool
    lee.eval("local g = ns.Bingo:GetGame(); g.raid = 'ssc'")
    w.tick(11)                                  # (Bob already asked when the raid formed: the ask is rate-limited)
    c["Bob"].eval("ns.Bingo:RequestState()")
    w.tick(3)
    for n in ("Rita", "Bob"):
        assert c[n].eval("return ns.Bingo:GetRaid()") == "ssc", n
    mine = c["Bob"].eval_py("return ns.Bingo:GetMyCard()")
    seen_by_lee = lee.eval_py("return ns.Bingo:GetCard(...)", K("Bob"))
    assert mine == seen_by_lee, "every client deals Bob the same card"
    pool = c["Bob"].eval("local n = 0; for _, id in ipairs(ns.Bingo:GetMyCard()) do local sq = ns.BingoSquares:Get(id) "
                         "if sq and sq.raid == 'ssc' then n = n + 1 end end; return n")
    assert pool >= 1, pool
    # once a square is marked the raid can't change (it would re-deal every card)
    lee.eval("ns.Bingo:Hit('wipe')")
    w.tick(2)
    lee.eval("local g = ns.Bingo:GetGame(); g.raid = 'kara'; ns.Bingo:Hit('lust')")
    w.tick(2)
    assert c["Bob"].eval("return ns.Bingo:GetRaid()") == "ssc"
    no_errors(w)


# -- points and Fated ----------------------------------------------------------------------------------------------------

@case
def points_count_each_quality_and_ten_a_line():
    w, c = solo("Alice", tick=2)
    c.slash("/dz bingo start")
    w.tick(0.5)
    assert c.eval("return ns.Bingo:GetPoints(ns.Util.PlayerKey())") == 0
    # the middle row (the centre is free): its four squares by quality + 10 for the line
    expect = c.eval("local card = ns.Bingo:GetMyCard(); local p = 0; for _, i in ipairs({ 11, 12, 14, 15 }) do "
                    "p = p + ns.BingoSquares:Points(card[i]); ns.Bingo:Hit(card[i]) end; return p + 10")
    w.tick(0.5)
    assert c.eval("return ns.Bingo:GetPoints(ns.Util.PlayerKey())") == expect
    row = c.eval_py("return ns.Games:GetData('bingo').season[ns.Util.PlayerKey()]")
    assert row["points"] == expect and row["bingos"] == 1, row
    no_errors(w)


@case
def fated_daubs_the_best_gap_on_every_client():
    w, c = raid()
    lee = start(w, c)
    # Rita's card: a line one square short (a row without her legendary), then her legendary goes off
    leg_cell = lee.eval("local _, cell = ns.Bingo:GetLegendary(...); return cell", K("Rita"))
    row = 0 if (leg_cell - 1) // 5 != 0 else 4
    cells = [row * 5 + k + 1 for k in range(5)]
    gap = next(i for i in cells if i != 13)
    others = [i for i in cells if i != gap and i != 13]
    lee.eval("local card = ns.Bingo:GetCard(...); for _, i in ipairs({ %s }) do ns.Bingo:Hit(card[i]) end"
             % ", ".join(map(str, others)), K("Rita"))
    w.tick(2)
    assert lee.eval("local l = ns.Bingo:GetScore(...); return l", K("Rita")) == 0
    lee.eval("local id = ns.Bingo:GetLegendary(...); ns.Bingo:Hit(id, 'Sam')", K("Rita"))
    w.tick(2)
    for n in ("Lee", "Rita", "Bob"):
        assert c[n].eval("return ns.Bingo:GetFated(...)", K("Rita")) == gap, n
        assert c[n].eval("local l = ns.Bingo:GetScore(...); return l", K("Rita")) >= 1, n
    # a raider can't hand out fates (Sam may hold the same legendary: his real fate, if any, stays)
    before = c["Bob"].eval("return ns.Bingo:GetFated(...)", K("Bob"))
    c["Sam"].eval("ns.Comm:Send({ t = 'BG', g = ns.Bingo:GetGame().id, h = {}, f = { [...] = 7 } }, 'RAID')", K("Bob"))
    w.tick(2)
    assert c["Bob"].eval("return ns.Bingo:GetFated(...)", K("Bob")) == before
    no_errors(w)


# -- moments, the Codex --------------------------------------------------------------------------------------------------

MOMENTS = ("BINGO_T = {}; ns:On('BINGO_MOMENT', function(id, who, mine) "
           "BINGO_T[#BINGO_T + 1] = id .. '|' .. tostring(who) .. '|' .. tostring(mine) end)")


@case
def a_moment_fires_once_per_new_square_and_stays_quiet_for_a_late_join():
    w, c = raid()
    for x in c.values():
        x.eval(MOMENTS)
    lee = start(w, c)
    lee.eval("ns.Bingo:Hit('ankh', 'Sam')")
    w.tick(2)
    lee.eval("ns.Bingo:Hit('lust')")
    w.tick(2)
    for n in ("Lee", "Bob"):
        got = c[n].eval_py("return BINGO_T")
        got = list(got.values()) if isinstance(got, dict) else got
        assert [g.split("|")[0] for g in got] == ["ankh", "lust"], (n, got)
        assert got[0].split("|")[1] == "Sam"
    # Bob loses the game and asks again: everything that already happened arrives at once, no fireworks
    c["Bob"].eval("BINGO_T = {}; ns.Games:GetData('bingo').current = nil; ns.Bingo:RequestState()")
    w.tick(3)
    assert c["Bob"].eval("return ns.Bingo:IsActive()")
    assert c["Bob"].eval("return #BINGO_T") == 0
    no_errors(w)


@case
def the_codex_remembers_what_happened_across_games():
    w, c = raid()
    lee = start(w, c)
    lee.eval("ns.Bingo:Hit('ankh', 'Sam')")
    w.tick(2)
    bob = c["Bob"]
    assert bob.eval("return ns.Bingo:GamesPlayed()") == 1
    e = bob.eval_py("return ns.Bingo:GetCodex().ankh")
    assert e["n"] == 1 and e["who"] == "Sam", e
    lee.slash("/dz bingo stop")
    w.tick(2)
    start(w, c)
    lee.eval("ns.Bingo:Hit('ankh')")
    w.tick(2)
    assert bob.eval("return ns.Bingo:GamesPlayed()") == 2
    assert bob.eval("return ns.Bingo:GetCodex().ankh.n") == 2
    assert bob.eval("return ns.Bingo:GetCodex().ankh.who") == "Sam", "the first one who set it off stays"
    no_errors(w)


@case
def epic_toasts_everyone_and_a_legendary_takes_over_the_open_card():
    w, c = raid()
    lee = start(w, c)
    rita = c["Rita"]
    open_card(w, rita)
    lee.eval("ns.Bingo:Hit('ankh', 'Sam')")
    w.tick(1)
    for n in ("Rita", "Bob"):
        assert c[n].eval("return ns.UI:GetToast('bingo:ankh') ~= nil"), n
    # a common or uncommon square: no toast
    lee.eval("ns.Bingo:Hit('wipe')")
    w.tick(1)
    assert not c["Bob"].eval("return ns.UI:GetToast('bingo:wipe') ~= nil")
    # Rita's legendary: the takeover on her open card, a toast for Bob (his window is closed)
    leg = lee.eval("return (ns.Bingo:GetLegendary(...))", K("Rita"))
    lee.eval("ns.Bingo:Hit(...)", leg)
    w.tick(1)
    assert rita.eval(WS + "return W.takeover:IsShown()")
    assert rita.eval("return ns.UI:GetToast('bingo:' .. ...) == nil", leg), "the takeover instead of a toast"
    assert c["Bob"].eval("return ns.UI:GetToast('bingo:' .. ...) ~= nil", leg)
    w.tick(8)
    assert not rita.eval(WS + "return W.takeover:IsShown()"), "it goes by itself"
    no_errors(w)


# -- the panel ----------------------------------------------------------------------------------------------------------

@case
def the_card_shows_quality_one_away_and_the_thread():
    w, c = solo("Alice", tick=2)
    c.slash("/dz bingo start")
    w.tick(0.5)
    open_card(w, c)
    leg_cell = c.eval("local _, cell = ns.Bingo:GetLegendary(ns.Util.PlayerKey()); return cell")
    assert c.eval(WS + "return W.cells[...].legendary == true", leg_cell)
    # column 1 (cells 1, 6, 11, 16, 21) four of five, unless the legendary is in it (then column 2)
    col = 1 if (leg_cell - 1) % 5 != 0 else 2
    cells = [col + 5 * r for r in range(5)]
    c.eval("local card = ns.Bingo:GetMyCard(); for _, i in ipairs({ %s }) do ns.Bingo:Hit(card[i]) end"
           % ", ".join(map(str, cells[:4])))
    w.tick(0.5)
    assert c.eval(WS + "return W.cells[...].away:IsShown()", cells[4]), "1 AWAY on the square still needed"
    assert "one away" in c.eval(WS + "return W.status:GetText()")
    # the thread: three links between the four marked squares (the column is line index 2 * col)
    shown = c.eval("local W = ns.BingoUI:GetWidgets(); local n = 0; for _, t in ipairs(W.threads[...]) do "
                   "if t.core:IsShown() then n = n + 1 end end; return n", 2 * col)
    assert shown == 3, shown
    no_errors(w)


@case
def card_and_codex_switch_on_the_hub_strip():
    w, c = solo("Alice", tick=2)
    c.slash("/dz bingo start")
    w.tick(0.5)
    c.eval("ns.Bingo:Hit('wipe')")
    open_card(w, c)
    assert c.eval(WS + "return W.seg:IsVisible() and W.seg:GetParent() ~= W.panel")
    c.eval(WS + "W.seg:Select('codex', true)")
    w.tick(0.2)
    assert c.eval(WS + "return W.codex:IsShown() and not W.card:IsShown()")
    total = c.eval("return #ns.BingoSquares.list")
    assert c.eval(WS + "return #W.codexCells") == total
    seen, unseen = c.eval(WS + "local a, b; for _, cell in ipairs(W.codexCells) do "
                          "if cell.sq.id == 'wipe' then a = cell.qi.qm:IsShown() end "
                          "if cell.sq.id == 'last_one' then b = cell.qi.qm:IsShown() end end; return a, b")
    assert seen is False and unseen is True, (seen, unseen)
    assert c.eval(WS + "return W.ladder[1]:IsShown()")
    c.eval("ns.BingoUI:SetView('card')")
    assert c.eval(WS + "return W.card:IsShown() and not W.codex:IsShown()")
    no_errors(w)


@case
def demo_mode_shows_a_made_up_game_and_never_sends_or_saves_it():
    w, c = raid()
    rita = c["Rita"]
    rita.eval("ns.Demo:SetEnabled(true)")
    open_card(w, rita)
    assert rita.eval("return ns.Bingo:IsDemo() and ns.Bingo:GetRaid() == 'ssc'")
    assert rita.eval("return ns.Games:GetData('bingo').current == nil"), "nothing saved"
    assert rita.eval("local l = ns.Bingo:GetScore(ns.Util.PlayerKey()); return l") >= 1
    # every quality's moment can be tried; nothing reaches the raid
    for q in ("c", "u", "r", "e", "l"):
        assert rita.eval("return ns.BingoUI:DemoMoment(...) ~= nil", q), q
        w.tick(0.3)
    assert rita.eval(WS + "return W.takeover:IsShown()")
    rita.eval("ns.Bingo:Hit('wipe'); ns.Bingo:Stop(); ns.Bingo:RequestState()")
    w.tick(3)
    for n in ("Lee", "Sam"):
        assert c[n].eval("return ns.Bingo:GetGame() == nil"), n
    assert rita.eval("return ns.Bingo:GetGame().hits.wipe == nil")
    # a real game started from demo mode is a real one
    rita.eval("ns.Demo:SetEnabled(false)")
    assert rita.eval("return ns.Bingo:GetGame() == nil")
    no_errors(w)


if __name__ == "__main__":
    run_all("games / Council Bingo cards")
