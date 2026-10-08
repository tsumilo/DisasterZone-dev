"""The Games hub (Games/HubUI.lua): the spotlight carousel on the real addon.

Covers: the tab opens on a carousel of every game (nothing selected, share ref "games"); arrows, mouse wheel, dots
and a click on a side poster turn it (animated, wrapping round); a click on the front poster grows it into the
game (strip + panel, share ref "game:<id>") and "< GAMES" goes back; links / Select open a game at once; the front
poster on opening is Bingo while a game runs (LIVE, "n square from a line"), else the game opened last; each
poster's stat comes from the game's saved data (Trainer best times + clears/tries, Azeromon badges / tamed,
Bingo season); covers never raise Lua errors while they animate.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_hub.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, strip_codes  # noqa: E402

POSTERS = "ns.GamesUI.__posters"


def hub(c):
    c.eval("ns.MainFrame:Open('games')")
    c.world.tick(0.5)


def front(c):
    return c.eval("return ns.GamesUI:GetFront()")


def poster(c, gid, field):
    return c.eval("for _, p in ipairs(%s) do if p.id == ... then return p.%s:GetText() end end" % (POSTERS, field), gid)


def settle(c, s=0.6):
    c.world.tick(s)
    assert c.eval("return ns.GamesUI:IsAnimating()") is False


@case
def tab_opens_on_the_carousel_and_turns_every_way():
    w, c = solo()
    c.world = w
    hub(c)
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    assert c.eval("return #%s" % POSTERS) == 3
    order = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.id end return o" % POSTERS)
    assert order == ["bingo", "trainer", "azeromon"], order
    start = front(c)
    i0 = order.index(start)
    # the right arrow: next game, animated
    c.eval("ns.GamesUI:Turn(%d)" % (i0 + 2))
    assert c.eval("return ns.GamesUI:IsAnimating()") is True
    settle(c)
    assert front(c) == order[(i0 + 1) % 3]
    # the mouse wheel (down = next) wraps round
    for _ in range(2):
        c.eval("local p for _, x in ipairs(%s) do if x.off == 0 then p = x end end "
               "p:GetScript('OnMouseWheel')(p, -1)" % POSTERS)
        settle(c)
    assert front(c) == start
    # a click on a side poster turns it to the front; a click on the front one doesn't turn
    c.eval("for _, p in ipairs(%s) do if p.off == -1 then p:Click() end end" % POSTERS)
    settle(c)
    assert front(c) == order[(i0 - 1) % 3]
    # a click while it turns is ignored (no half-turned carousel)
    c.eval("ns.GamesUI:Turn(1)")
    c.eval("for _, p in ipairs(%s) do if p.off == 1 then p:Click() end end" % POSTERS)
    settle(c)
    assert front(c) == "bingo"
    # exactly one poster in front, the others dimmed at the sides
    offs = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.off end return o" % POSTERS)
    assert sorted(offs) == [-1, 0, 1], offs
    no_errors(w)


@case
def front_poster_grows_into_the_game_and_back_returns():
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('trainer')")
    c.eval("for _, p in ipairs(%s) do if p.off == 0 then p:Click() end end" % POSTERS)
    assert c.eval("return ns.GamesUI:IsAnimating()") is True
    assert c.eval("return ns.GamesUI:GetSelected()") is None       # (still growing)
    settle(c)
    assert c.eval("return ns.GamesUI:GetSelected()") == "trainer"
    assert c.eval("return ns.Share:CurrentRef()") == "game:trainer"
    shown = c.eval_py("return { strip = ns.GamesUI.__posters[1]:GetParent():IsVisible() }")
    assert shown["strip"] is False                                  # the carousel is gone
    # the strip's "< GAMES" back to the carousel, the same game in front
    c.eval("local f = ns.MainFrame:GetFrame() "
           "local function find(fr) for _, ch in ipairs({ fr:GetChildren() }) do "
           "  if ch.fs and ch.fs.GetText and ch.fs:GetText() == 'GAMES' and ch:IsVisible() then return ch end "
           "  local x = find(ch) if x then return x end end end "
           "find(f):Click()")
    settle(c)
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    assert front(c) == "trainer"
    assert c.eval("return ns.Share:CurrentRef()") == "games"
    no_errors(w)


@case
def links_open_a_game_at_once_and_it_comes_first_next_time():
    w, c = solo()
    c.world = w
    c.eval("ns.Games:Open('azeromon')")
    w.tick(0.2)
    assert c.eval("return ns.GamesUI:GetSelected()") == "azeromon"
    assert c.eval("return ns.GamesUI:IsAnimating()") is False
    c.eval("ns.GamesUI:ShowHub()")
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.2)
    hub(c)
    assert front(c) == "azeromon"
    no_errors(w)


@case
def a_running_bingo_game_comes_first_and_says_how_close_you_are():
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('azeromon')")
    c.eval("local d, me, now = ns.Games:GetData('bingo'), ns.Util.PlayerKey(), time() "
           "d.current = { id = 'hubtest', host = me, started = now, hits = {} } "
           "local card = ns.Bingo:GetMyCard() "
           "for _, i in ipairs({ 1, 7, 19 }) do d.current.hits[card[i]] = now - 60 end")
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.2)
    hub(c)
    assert front(c) == "bingo"
    assert strip_codes(poster(c, "bingo", "kicker")).startswith("LIVE")
    assert strip_codes(poster(c, "bingo", "stat")) == "1 square from a line"
    assert strip_codes(poster(c, "bingo", "footText")) == "1 playing"
    # the missing square of that diagonal is the one marked as needed; the stamps are my dauber
    need = c.eval_py("for _, p in ipairs(%s) do if p.id == 'bingo' then local o = {} "
                     "for i in pairs(p.cover.need) do o[#o + 1] = i end return o end end" % POSTERS)
    assert need == [25], need
    w.tick(2)                                                       # (the pulse runs without errors)
    # once it ends, the next raid / season shows again
    c.eval("ns.Games:GetData('bingo').current.ended = true")
    w.tick(3.5)
    assert not strip_codes(poster(c, "bingo", "kicker")).startswith("LIVE")
    no_errors(w)


@case
def poster_stats_come_from_each_games_saved_data():
    w, c = solo()
    c.world = w
    c.eval("local d = ns.Games:GetData('trainer') "
           "d.enc = { vashj = { looter = { tries = 3, clears = 1, bestTime = 271.4 } }, "
           "          teron = { quick = { tries = 2, clears = 0 } } } d.last = 'vashj'")
    c.eval("local s = { flags = {}, caught = { a = true, b = true }, seen = {} } "
           "local n = 0 for id in pairs(ns.AzeroData.badges) do n = n + 1 if n <= 2 then s.flags['badge_' .. id] = true end end "
           "ns.Games:GetData('azeromon').save = s")
    hub(c)
    assert strip_codes(poster(c, "trainer", "stat")) == "1 clear  ·  5 tries"
    chips = c.eval_py("for _, p in ipairs(%s) do if p.id == 'trainer' then local o = {} "
                      "for i, ch in ipairs(p.cover.shown) do o[i] = { ch.name:GetText(), ch.time:GetText() } end "
                      "return o end end" % POSTERS)
    assert [ch[0] for ch in chips] == ["Lady Vashj", "Teron Gorefiend"], chips
    assert chips[0][1] == "4:31" and strip_codes(chips[1][1]) == "not cleared", chips
    total = c.eval("local n = 0 for _ in pairs(ns.AzeroData.badges) do n = n + 1 end return n")
    assert strip_codes(poster(c, "azeromon", "stat")) == "Badges 2 of %d  ·  2 tamed" % total
    no_errors(w)


@case
def hiding_the_tab_mid_turn_or_mid_open_leaves_a_clean_state():
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:Turn(ns.GamesUI.__posters[1].off == 0 and 2 or 1)")
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.5)
    hub(c)
    assert c.eval("return ns.GamesUI:IsAnimating()") is False
    c.eval("for _, p in ipairs(%s) do if p.off == 0 then p:Click() end end" % POSTERS)
    w.tick(0.05)
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.3)
    assert c.eval("return ns.GamesUI:IsAnimating()") is False
    assert c.eval("return ns.GamesUI:GetSelected()") is not None   # (the open finished: the game is open)
    no_errors(w)


if __name__ == "__main__":
    run_all("games / hub")
