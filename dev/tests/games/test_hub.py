"""The Games hub (Games/HubUI.lua): the spotlight carousel on the real addon.

Covers: the tab opens on a carousel of every game (nothing selected, share ref "games"); arrows, mouse wheel, dots
and a click on a side poster turn it (animated, wrapping round); a click on the front poster grows it into the
game (strip + panel, share ref "game:<id>") and "< GAMES" goes back; links / Select open a game at once; the front
poster on opening is Bingo while a game runs (LIVE, "n square from a line"), else the game opened last; each
poster's stat comes from the game's saved data (Trainer best times + clears/tries, Disastercraft's best character,
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
    assert c.eval("return #%s" % POSTERS) == 4
    order = c.eval_py("local o = {} for i, p in ipairs(%s) do o[i] = p.id end return o" % POSTERS)
    assert order == ["bingo", "trainer", "disastercraft", "chess"], order
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


ALPHAS = ("local car = ns.GamesUI.__posters[1]:GetParent() local root = car:GetParent() local o = {} "
          "for _, ch in ipairs({ root:GetChildren() }) do o[#o + 1] = ch:IsShown() and ch:GetAlpha() or -1 end return o")


@case
def the_open_and_the_way_back_are_one_crossfade():
    """Paused and stepped by hand: the poster grows first with the game invisible, then the carousel fades out
    exactly as the strip and the game fade in; back runs the other way and ends on the same poster in front."""
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('disastercraft') ns.GamesUI:PauseAnim(true)")
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
    assert c.eval("return ns.GamesUI:GetSelected()") == "disastercraft"
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
    assert front(c) == "disastercraft"
    assert c.eval("for _, p in ipairs(%s) do if p.off == 0 then return p.over:GetAlpha() end end" % POSTERS) == 1
    c.eval("ns.GamesUI:PauseAnim(false)")
    no_errors(w)


@case
def links_open_a_game_at_once_and_it_comes_first_next_time():
    w, c = solo()
    c.world = w
    c.eval("ns.Games:Open('disastercraft')")
    w.tick(0.2)
    assert c.eval("return ns.GamesUI:GetSelected()") == "disastercraft"
    assert c.eval("return ns.GamesUI:IsAnimating()") is False
    c.eval("ns.GamesUI:ShowHub()")
    assert c.eval("return ns.GamesUI:GetSelected()") is None
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.2)
    hub(c)
    assert front(c) == "disastercraft"
    no_errors(w)


@case
def a_running_bingo_game_comes_first_and_says_how_close_you_are():
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('disastercraft')")
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
    c.eval("ns.Games:GetData('disastercraft').chars = { [1] = { v = 1, class = 1, level = 4, done = { [7] = true, [783] = true } }, "
           "[8] = { v = 1, class = 8, level = 2, done = { [5261] = true } } }")
    hub(c)
    assert strip_codes(poster(c, "trainer", "stat")) == "1 clear  ·  5 tries"
    chips = c.eval_py("for _, p in ipairs(%s) do if p.id == 'trainer' then local o = {} "
                      "for i, ch in ipairs(p.cover.shown) do o[i] = { ch.name:GetText(), ch.time:GetText() } end "
                      "return o end end" % POSTERS)
    assert [ch[0] for ch in chips] == ["Lady Vashj", "Teron Gorefiend"], chips
    assert chips[0][1] == "4:31" and strip_codes(chips[1][1]) == "not cleared", chips
    got = strip_codes(poster(c, "disastercraft", "stat"))
    assert got == "Level 4 Warrior  ·  3 quests", repr(got)
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


FILM = ("local p for _, x in ipairs(ns.GamesUI.__posters) do if x.id == 'disastercraft' then p = x end end "
        "local f = p.cover ")


@case
def disastercraft_poster_plays_a_film_of_northshire_on_a_loop():
    """Disastercraft's cover is a film of the real Northshire: shots one after another, each with its place's name
    (on the front poster only), cross-fading from one to the next and round again; the heroes, the creatures and the
    fight's Fireballs and numbers are drawn; all of it stays under the poster's shades and words."""
    w, c = solo()
    c.world = w
    hub(c)
    c.eval("ns.GamesUI:ShowFront('disastercraft')")
    settle(c)
    names = c.eval_py("local o = {} for i, s in ipairs(ns.GamesUI.Film.SHOTS) do o[i] = s.name end return o")
    assert names == ["Northshire Abbey", "Echo Ridge Mine", "Northshire Vineyards", "Northshire Valley"], names
    # the first shot: the Abbey's name in gold once it has come up, the heroes and the valley's NPCs on the sheets
    c.eval("ns.GamesUI:FilmSeek(1, 3)")
    got = c.eval_py(FILM + "local L = f.reels[f.live] local bodies = 0 "
                    "for _, pool in ipairs(L.pools) do for _, t in ipairs(pool) do "
                    "  if t:IsShown() and tostring(t.file):find('mobs') then bodies = bodies + 1 end end end "
                    "return { cap = f.cap:GetText(), a = f.cap:GetAlpha(), bodies = bodies, art = p.art:IsShown() }")
    assert got["cap"] == "Northshire Abbey" and got["a"] > 0.95, got
    assert got["bodies"] >= 4, got                  # (three heroes and Deputy Willem at least)
    assert got["art"] is False, got                 # (no loading screen behind the film)
    # the cut: the next shot's name takes over unseen and comes up a beat after; its picture comes up over the last
    # one (both reels shown), then the last one goes
    c.eval("ns.GamesUI:FilmSeek(1, 8.5 + 0.2)")
    cut = c.eval_py(FILM + "return { cap = f.cap:GetText(), on = f.cap:IsShown() }")
    assert cut == {"cap": "Echo Ridge Mine", "on": False}, cut
    c.eval("ns.GamesUI:FilmSeek(1, 8.5 + 0.7)")
    mid = c.eval_py(FILM + "return { a1 = f.reels[1].frame:IsShown() and f.reels[1].frame:GetAlpha() or -1, "
                    "a2 = f.reels[2].frame:IsShown() and f.reels[2].frame:GetAlpha() or -1, i = f.shotIdx }")
    assert mid["a1"] == 1 and 0.3 < mid["a2"] < 0.7 and mid["i"] == 2, mid
    w.tick(1.0)
    after = c.eval_py(FILM + "return { r1 = f.reels[1].frame:IsShown(), live = f.live, cap = f.cap:GetText() }")
    assert after == {"r1": False, "live": 2, "cap": "Echo Ridge Mine"}, after
    # the fight: the first Fireball's number over the kobold, later the kobold's corpse
    c.eval("ns.GamesUI:FilmSeek(2, 2.6)")
    nums = c.eval_py(FILM + "local o = {} for _, fs in ipairs(f.reels[1].nums) do if fs:IsShown() then o[#o + 1] = fs:GetText() end end return o")
    assert "41" in nums, nums
    assert c.eval(FILM + "return f.reels[1].cast.foe.act") is None
    c.eval("ns.GamesUI:FilmSeek(2, 7)")
    assert c.eval(FILM + "return f.reels[1].cast.foe.act") == "dead"
    # a whole loop: every place's name comes up, in order, and it comes round to the Abbey again
    c.eval("ns.GamesUI:FilmSeek(1, 0)")
    seen = []
    for _ in range(int(4 * 8.5 / 0.5) + 6):
        w.tick(0.5)
        cap = c.eval(FILM + "return f.cap:GetText()")
        if not seen or seen[-1] != cap:
            seen.append(cap)
    assert seen[:5] == names + ["Northshire Abbey"], seen
    # the film's frames all sit under the poster's shades and words, on the front and at the side
    for gid in ("disastercraft", "chess"):
        c.eval("ns.GamesUI:ShowFront('%s')" % gid)
        settle(c)
        lv = c.eval_py(FILM + "local hi = 0 local function walk(fr) hi = math.max(hi, fr:GetFrameLevel()) "
                       "for _, ch in ipairs({ fr:GetChildren() }) do walk(ch) end end walk(f) "
                       "return { film = hi, over = p.over:GetFrameLevel(), cap = f.cap:IsShown() and f.cap:GetAlpha() or 0, "
                       "  rule = f.capRule:IsShown() and 1 or 0, rw = f.capRule:GetWidth() + 2 * f.capFade[1]:GetWidth(), w = f.vw or 300 }")
        assert lv["film"] < lv["over"], lv
        if gid == "chess":
            assert lv["cap"] == 0 and lv["rule"] == 0, lv   # (a side poster shows no name, nor its underline)
        else:
            assert lv["rw"] <= lv["w"], lv                   # (the underline stays inside the card)
    no_errors(w)


if __name__ == "__main__":
    run_all("games / hub")
