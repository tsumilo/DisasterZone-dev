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


def summary(c, gid):
    """The poster's numbers as text ("53 clears  ·  97 tries ..."), or its one stat line."""
    return c.eval("for _, p in ipairs(%s) do if p.id == ... then return p.summary end end" % POSTERS, gid)


def settle(c, s=0.6):
    c.world.tick(s)
    assert c.eval("return ns.GamesUI:IsAnimating()") is False


@case
def tab_opens_on_the_carousel_and_turns_every_way():
    w, c = solo()
    c.world = w
    hub(c)
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    assert c.eval("return #%s" % POSTERS) == 6
    order = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.id end return o" % POSTERS)
    assert order == ["bingo", "trainer", "azeromon", "chess", "illidan", "holdtheline"], order
    n = len(order)
    start = front(c)
    i0 = order.index(start)
    # the right arrow: next game, animated
    c.eval("ns.GamesUI:Turn(%d)" % (i0 + 2))
    assert c.eval("return ns.GamesUI:IsAnimating()") is True
    settle(c)
    assert front(c) == order[(i0 + 1) % n]
    # the mouse wheel (down = next) wraps round
    for _ in range(n - 1):
        c.eval("local p for _, x in ipairs(%s) do if x.off == 0 then p = x end end "
               "p:GetScript('OnMouseWheel')(p, -1)" % POSTERS)
        settle(c)
    assert front(c) == start
    # a click on a side poster turns it to the front; a click on the front one doesn't turn
    c.eval("for _, p in ipairs(%s) do if p.off == -1 then p:Click() end end" % POSTERS)
    settle(c)
    assert front(c) == order[(i0 - 1) % n]
    # a click while it turns is ignored (no half-turned carousel)
    c.eval("ns.GamesUI:Turn(1)")
    c.eval("for _, p in ipairs(%s) do if p.off == 1 then p:Click() end end" % POSTERS)
    settle(c)
    assert front(c) == "bingo"
    # exactly one poster in front, the others dimmed at the sides
    offs = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.off end return o" % POSTERS)
    assert [o for o in sorted(offs) if -1 <= o <= 1] == [-1, 0, 1] and len(offs) == n, offs   # (the rest off stage)
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
def azeromon_poster_is_a_film_of_the_game_crossfading_shot_to_shot():
    """Azeromon's poster plays its film (Games/Azeromon/Poster.lua): every shot draws the baked ground, its props and
    the walking hero; the next shot fades in on the upper reel over the last 1.6 s, then the reels swap."""
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('azeromon') ns.GamesUI:PauseAnim(true)")
    FILM = ("local f for _, p in ipairs(%s) do if p.id == 'azeromon' then f = p.cover end end " % POSTERS)
    n = c.eval(FILM + "return #ns.AzeroPoster.SHOTS")
    assert n >= 5, n
    for i in range(1, n + 1):
        got = c.eval_py(FILM + "f:Seek(%d, 3) f:Tick(0.01) local r = f.reels[1] "
                        "return { r.view:IsShown(), r.hero:IsShown(), #r.pools.ground, #r.pools.over, "
                        "f.reels[2].view:IsShown() }" % i)
        assert got[0] and got[1], (i, got)
        assert got[2] > 0 and got[3] > 0, (i, got)                 # the baked ground and the props are drawn
        assert not got[4], (i, got)                                 # (no second shot mid-shot; a tick is at most 0.1 s)
    # the last 1.6 s: the next shot over it, half faded in at 7.2 s; past 8 s it is the shot playing
    up = c.eval_py(FILM + "f:Seek(1, 7.2) f:Tick(0.01) local u = f.reels[2] return { u.view:IsShown(), u.view:GetAlpha() }")
    assert up[0] and 0.3 < up[1] < 0.7, up
    shot = c.eval(FILM + "for _ = 1, 9 do f:Tick(0.1) end return f.shot")
    assert shot == 2, shot
    # on the side (Azeromon has no painting): a still of the shot it was on, which holds while the front one plays
    c.eval("ns.GamesUI:ShowFront('chess')")
    side = c.eval_py(FILM + "f:Tick(0.05) local t = f.t f:Tick(0.05) local r = f.reels[1] "
                     "return { f:IsShown(), r.view:IsShown(), r.hero:IsShown(), f.t == t }")
    assert side == [True, True, True, True], side
    no_errors(w)


ALPHAS = ("local car = ns.GamesUI.__posters[1]:GetParent() local root = car:GetParent() local o = {} "
          "for _, ch in ipairs({ root:GetChildren() }) do o[#o + 1] = ch:IsShown() and ch:GetAlpha() or -1 end return o")


@case
def the_open_and_the_way_back_are_one_crossfade():
    """Paused and stepped by hand: the poster grows first with the game invisible, then the carousel fades out
    exactly as the strip and the game fade in; back runs the other way and ends on the same poster in front."""
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('azeromon') ns.GamesUI:PauseAnim(true)")
    c.eval("for _, p in ipairs(%s) do if p.off == 0 then p:Click() end end" % POSTERS)
    c.eval("ns.GamesUI:StepAnim(0.2)")
    car, strip, stage = c.eval_py(ALPHAS)[0:3]
    assert car == 1 and strip == 0 and stage == 0, (car, strip, stage)
    words = c.eval("for _, p in ipairs(%s) do if p.off == 0 then return p.over:GetAlpha() end end" % POSTERS)
    assert words < 0.1, words                                       # (the poster's words have gone)
    c.eval("ns.GamesUI:StepAnim(0.2)")
    car, strip, stage = c.eval_py(ALPHAS)[0:3]
    assert 0 < strip < 1 and abs(car + strip - 1) < 0.01, (car, strip)
    c.eval("ns.GamesUI:StepAnim(0.3)")
    assert c.eval("return ns.GamesUI:GetSelected()") == "azeromon"
    assert c.eval("return ns.GamesUI:IsAnimating()") is False
    # back: the game fades while the poster comes back; nothing selected from the first frame
    c.eval("local function find(fr) for _, ch in ipairs({ fr:GetChildren() }) do "
           "  if ch.fs and ch.fs.GetText and ch.fs:GetText() == 'GAMES' and ch:IsVisible() then return ch end "
           "  local x = find(ch) if x then return x end end end "
           "find(ns.MainFrame:GetFrame()):Click()")
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    c.eval("ns.GamesUI:StepAnim(0.1)")
    car, strip = c.eval_py(ALPHAS)[0:2]
    assert car == 1 and 0 < strip < 1, (car, strip)
    c.eval("ns.GamesUI:StepAnim(0.5)")
    car, strip = c.eval_py(ALPHAS)[0:2]
    assert car == 1 and strip == -1, (car, strip)                   # (the strip is hidden again)
    assert front(c) == "azeromon"
    assert c.eval("for _, p in ipairs(%s) do if p.off == 0 then return p.over:GetAlpha() end end" % POSTERS) == 1
    c.eval("ns.GamesUI:PauseAnim(false)")
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
    assert summary(c, "bingo").startswith("1 from a line"), summary(c, "bingo")
    assert poster(c, "bingo", "cta") == "JOIN"
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
    assert summary(c, "trainer") == "1 clear  ·  5 tries  ·  20% clear rate", summary(c, "trainer")
    chips = c.eval_py("for _, p in ipairs(%s) do if p.id == 'trainer' then local o = {} "
                      "for i, ch in ipairs(p.cover.shown) do o[i] = { ch.name:GetText(), ch.time:GetText() } end "
                      "return o end end" % POSTERS)
    assert [ch[0] for ch in chips] == ["Lady Vashj", "Teron Gorefiend"], chips
    assert chips[0][1] == "4:31" and strip_codes(chips[1][1]) == "not cleared", chips
    total = c.eval("local n = 0 for _ in pairs(ns.AzeroData.badges) do n = n + 1 end return n")
    assert summary(c, "azeromon") == "2/%d badges  ·  2 tamed" % total, summary(c, "azeromon")
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


@case
def the_dots_stretch_and_take_the_colour_with_the_turn():
    """The front game's dot is a pill in its colour; a turn shrinks and greys the old one while the new one stretches
    and takes its colour, at the posters' pace (half-way: both between a dot and a pill)."""
    w, c = solo()
    c.world = w
    hub(c)
    order = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.id end return o" % POSTERS)
    i0 = order.index(front(c))
    d = c.eval_py("return ns.GamesUI.__dots()")
    assert d[i0][0] == 20 and all(x[0] == 6 for k, x in enumerate(d) if k != i0), d
    assert abs(d[i0][4] - 1) < 1e-6 and all(abs(x[4] - 0.24) < 1e-6 for k, x in enumerate(d) if k != i0), d
    i1 = (i0 + 1) % len(order)
    c.eval("ns.GamesUI:PauseAnim(true) ns.GamesUI:Turn(%d) ns.GamesUI:StepAnim(0.16)" % (i1 + 1))
    d = c.eval_py("return ns.GamesUI.__dots()")
    assert 6 < d[i0][0] < 20 and 6 < d[i1][0] < 20, d                    # both on their way
    assert 0.24 < d[i1][4] < 1 and 0.24 < d[i0][4] < 1, d
    c.eval("ns.GamesUI:StepAnim(0.3) ns.GamesUI:PauseAnim(false)")
    d = c.eval_py("return ns.GamesUI.__dots()")
    assert d[i1][0] == 20 and d[i0][0] == 6, d
    assert abs(d[i1][4] - 1) < 1e-6 and abs(d[i0][4] - 0.24) < 1e-6, d
    no_errors(w)


@case
def games_send_uses_the_game_class_and_stamps_a_registered_version_peek_creates_nothing():
    w, c = solo()
    c.eval("_G.__gsent = {} local send = ns.Comm.Send "
           "ns.Comm.Send = function(self, msg, dist, target, class) "
           "table.insert(_G.__gsent, { t = msg.t, v = msg.v, dist = dist, to = target, class = class }) "
           "return send(self, msg, dist, target, class) end")
    c.eval("ns.Games:Send('nogame', { t = 'XX1' }, 'GUILD')")
    c.eval("ns.Chess:Whisper('Bob', { t = 'CHX', id = 'g1' })")
    assert c.eval("return ns.Games:Send('chess', { t = 'CHX' }, 'WHISPER', nil)") is False
    sent = c.eval_py("return _G.__gsent")
    assert sent[0] == {"t": "XX1", "dist": "GUILD", "class": "game"}, sent
    assert sent[1] == {"t": "CHX", "v": c.eval("return ns.Chess.VERSION"), "dist": "WHISPER", "to": "Bob",
                       "class": "game"}, sent
    assert len(sent) == 2, sent
    # PeekData looks without creating the game's table
    c.eval("ns.db.games = ns.db.games or {} ns.db.games.peeked = nil")
    assert c.eval("local t = ns.Games:PeekData('peeked') return next(t) == nil") is True
    assert c.eval("return ns.db.games.peeked") is None
    c.eval("ns.Games:GetData('peeked').x = 3")
    assert c.eval("return ns.Games:PeekData('peeked').x") == 3
    no_errors(w)


@case
def the_bingo_counter_keeps_its_1_3_place_and_then_uses_the_one_position_store():
    w, c = solo()
    c.eval("ns.Games:GetData('bingo').miniPos = { 'TOPLEFT', 'TOPLEFT', 120, -80 } "
           "if ns.db.settings.windows then ns.db.settings.windows.bingoMini = nil end")
    c.relog()
    w.tick(2)
    where = "local p, _, r, x, y = DisasterZoneBingoMini:GetPoint(1) return { p, r, x, y }"
    assert c.eval_py(where) == ["TOPLEFT", "TOPLEFT", 120, -80]
    assert c.eval("return ns.Games:GetData('bingo').miniPos") is None
    assert c.eval_py("return ns.db.settings.windows.bingoMini") == ["TOPLEFT", "TOPLEFT", 120, -80]
    # dragged: saved in the one store, and there after the next login
    c.eval("local f = DisasterZoneBingoMini f:ClearAllPoints() f:SetPoint('CENTER', UIParent, 'CENTER', 40, 30) "
           "f:GetScript('OnDragStop')(f)")
    c.relog()
    w.tick(2)
    assert c.eval_py(where) == ["CENTER", "CENTER", 40, 30]
    no_errors(w)


if __name__ == "__main__":
    run_all("games / hub")
