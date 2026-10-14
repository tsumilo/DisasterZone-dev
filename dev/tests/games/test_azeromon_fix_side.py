"""Azeromon: edge cases in the side systems (guild board, achievements toast, gathering, trainers, the Guild Hall,
bounties, sounds).

Covers, one case per fix: a summary sent from saved data with the game closed carries the real profile (and a field
left out keeps the old value); alts of one account show once, players who left or went quiet drop off the board;
clicking a toast moves the queue on; a node never stays on a herb above the player's skill; the profession trainer
forgets the old trade only once the new one is picked and paid for; the Chess Event has a plinth and the hall's
layout holds; a kill is not judged before the guild roster is in, and a kill once judged the guild's keeps its
trophy; the board's rankings are cached (the hall's statues ask every frame); "First in the Guild" survives a wrong
clock and is looked at again when summaries arrive; the bounty day key holds whatever the client says about the
reset; a new game pays nothing again; one sound per bounty and guild tier.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fix_side.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

DAY = 86400


def guild(names=("Alice", "Bob", "Carol", "Dave")):
    w = World()
    cs = {n: Client(w, n, guild_rank=3) for n in names}
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    for c in cs.values():
        c.eval(BOT)
        c.eval("T_AZ.seed(3)")
    return w, cs


def game(seed=7, members=()):
    w, c = solo("Alice", tick=2, members=list(members))
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    return w, c


def tame(c, *species):
    for sp in species:
        c.eval("ns.Azero:AddMon(ns.AzeroMon.New(%r, 5, ns.Azero.rng), 'caught')" % sp)


def stored(c, name):
    return c.eval_py("for k, e in pairs(ns.Azero:Data().guild or {}) do if e.name == %r then "
                     "local t = {} for id in pairs(e.caught or {}) do t[#t+1] = id end table.sort(t) "
                     "return { n = e.n, b = e.b, ap = e.ap, wk = e.wk, wn = e.wn, caught = t, id = e.id, done = e.done } "
                     "end end" % name)


def texts_until_choice(c):
    out = []
    for _ in range(20):
        p = c.eval_py("local p = ns.Azero.pending return p and { kind = p.kind, text = p.text }")
        if not p or p["kind"] != "text":
            break
        out.append(p["text"])
        c.eval("ns.Azero:Advance()")
    return out


# 1 ---------------------------------------------------------------------------------------------------------------
@case
def a_reply_with_the_game_closed_sends_the_real_profile():
    w, cs = guild(("Alice", "Bob", "Carol"))
    a, b, carol = cs["Alice"], cs["Bob"], cs["Carol"]
    carol.eval("ns.Azero:NewGame()")
    tame(carol, "owlet", "kobling", "coyote")
    carol.eval("ns.Azero:SetFlag('badge_hogger') ns.AzeroAch:Award('rival')")
    carol.eval("local st = ns.AzeroBounty:State() st.wn = 4")
    ap = carol.eval("return ns.AzeroAch:Points()")
    week = carol.eval("return ns.AzeroBounty:State().week")
    carol.relog()                                      # a new session: the game not opened, G.save not loaded
    w.tick(3)
    assert carol.eval("return ns.Azero.save == nil") is True
    b.eval("ns.Azero:NewGame()")
    assert b.eval("return ns.AzeroGuild:Query()") is True
    w.tick(5)
    e = stored(b, "Carol")
    assert e and e["n"] == 3 and e["caught"] == ["coyote", "kobling", "owlet"], e
    assert e["b"] == 1 and e["ap"] == ap and ap >= 10 and e["wk"] == week and e["wn"] == 4, e
    assert carol.eval("return ns.Azero.save == nil") is True        # answering never loaded the game
    # a field left out keeps what Bob knew; a field sent but bad still counts as 0
    a.eval("ns.Comm:Send({ t = 'AZS', v = 1, c = { 1, 2 }, ap = 50, wk = %d, wn = 3 }, 'GUILD', nil, 'game')" % week)
    w.tick(0.5)
    a.eval("ns.Comm:Send({ t = 'AZS', v = 1, b = 'lots' }, 'GUILD', nil, 'game')")
    w.tick(0.5)
    e = stored(b, "Alice")
    assert e["n"] == 2 and e["ap"] == 50 and e["wk"] == week and e["wn"] == 3 and e["b"] == 0, e
    no_errors(w)


# 2 ---------------------------------------------------------------------------------------------------------------
@case
def alts_show_once_and_leavers_drop_off_the_board():
    w, cs = guild(("Alice", "Bob", "Carol", "Dave"))
    a, b, carol, dave = cs["Alice"], cs["Bob"], cs["Carol"], cs["Dave"]
    b.eval("ns.Azero:NewGame()")
    week = b.eval("return ns.AzeroBounty:State().week")
    # Carol and Dave are one account (the same save): the same id, the same weekly part
    for c in (carol, dave):
        c.eval("ns.Comm:Send({ t = 'AZS', v = 1, id = 'acct7', c = { 1, 2, 3 }, wk = %d, wn = 5 }, 'GUILD', nil, 'game')" % week)
        w.tick(0.5)
    names = b.eval_py("local t = {} for _, e in ipairs(ns.AzeroGuild:Entries()) do t[#t+1] = e.name end table.sort(t) return t")
    assert names == ["Bob", "Dave"], names                          # the character heard from last
    total = b.eval_py("local t, p = ns.AzeroGuild:WeeklyTotal(%d) return { t, p }" % week)
    assert total == [5, 1], total
    # someone else answering with my own account's id (my alt, echoed) is me: not a second entry
    uid = b.eval("return ns.AzeroGuild.MyUid()")
    assert uid and len(uid) == 10
    a.eval("ns.Comm:Send({ t = 'AZS', v = 1, id = %r, c = { 1 } }, 'GUILD', nil, 'game')" % uid)
    w.tick(0.5)
    names = b.eval_py("local t = {} for _, e in ipairs(ns.AzeroGuild:Entries()) do t[#t+1] = e.name end table.sort(t) return t")
    assert names == ["Bob", "Dave"], names
    # my id survives a new game (alts and new games keep one id per account)
    b.eval("ns.Azero:NewGame()")
    assert b.eval("return ns.AzeroGuild.MyUid()") == uid
    # someone who left the guild, and someone not heard from for a month, drop off
    b.eval("""local realm = ns.AzeroGuild.MyKey():match('%-(.*)$')
      local store, now = ns.Azero:Data().guild, GetServerTime()
      store['Zed-' .. realm] = { name = 'Zed', n = 9, caught = {}, seen = now }
      store['Carol-' .. realm] = { name = 'Carol', n = 4, caught = {}, seen = now - 31 * 86400 }
      ns.AzeroGuild.Invalidate()""")
    names = b.eval_py("local t = {} for _, e in ipairs(ns.AzeroGuild:Entries()) do t[#t+1] = e.name end table.sort(t) return t")
    assert names == ["Bob", "Dave"], names
    left = b.eval_py("local t = {} for k, e in pairs(ns.Azero:Data().guild) do t[#t+1] = e.name end table.sort(t) return t")
    assert left == ["Dave"], left
    no_errors(w)


# 3 ---------------------------------------------------------------------------------------------------------------
@case
def clicking_a_toast_shows_the_next_one():
    w, c = game()
    c.eval("""local A = ns.AzeroAch
      A:Notify({ label = 'One', name = 'First toast', icon = 'x', sound = false })
      A:Notify({ label = 'Two', name = 'Second toast', icon = 'x', sound = false })""")
    shown = c.eval_py("local f = ns.AzeroAch:ToastFrame() return { f:IsShown(), f.name:GetText() }")
    assert shown == [True, "First toast"], shown
    c.eval("local f = ns.AzeroAch:ToastFrame() f:GetScript('OnClick')(f)")
    shown = c.eval_py("local f = ns.AzeroAch:ToastFrame() return { f:IsShown(), f.name:GetText() }")
    assert shown == [True, "Second toast"], shown
    c.eval("local f = ns.AzeroAch:ToastFrame() f:GetScript('OnClick')(f)")
    assert c.eval("return ns.AzeroAch:ToastFrame():IsShown()") is False
    c.eval("T_AZ.settle()")
    no_errors(w)


# 4 ---------------------------------------------------------------------------------------------------------------
@case
def a_node_never_stays_on_a_herb_above_the_players_skill():
    w, c = game()
    r = c.eval_py("""local C, G = ns.AzeroCraft, ns.Azero
      local node = { x = 0, y = 0, list = { 'mageroyal', 'peacebloom', 'briarthorn' } }
      local out = {}
      G.save.prof = { herbalism = 10 }
      out[1] = select(2, C:NodeState('route1', node))
      G.save.nodes = { ['route1:0:0'] = { t = 0, n = 2 } }          -- its turn: Briarthorn (70)
      out[2] = select(2, C:NodeState('route1', node))
      G.save.prof = { herbalism = 75 }
      out[3] = select(2, C:NodeState('route1', node))               -- skilled enough: the node's own turn
      G.save.prof = {}
      out[4] = select(2, C:NodeState('route1', node))               -- no Herbalism: shown as it is
      return out""")
    assert r == ["peacebloom", "peacebloom", "briarthorn", "briarthorn"], r
    no_errors(w)


# 5 ---------------------------------------------------------------------------------------------------------------
@case
def the_trainer_forgets_the_old_trade_only_once_the_new_one_is_paid():
    w, c = game()
    c.eval("ns.Azero.save.prof = { herbalism = 40, mining = 30 } ns.Azero.save.money = 200")

    def to_learn_choice():
        c.eval("ns.Azero:EnterMap('town', 8, 4, 'up', true) ns.Azero:PressA()")
        texts_until_choice(c)
        assert c.eval_py("return ns.Azero.pending.options") == ["Forget Herbalism", "Forget Mining"]
        c.eval("ns.Azero:Advance(2)")                                  # Forget Mining
        c.eval("ns.Azero:Advance(1)")                                  # Yes
        texts_until_choice(c)
        assert c.eval_py("return ns.Azero.pending.options") == ["Learn Alchemy"]

    to_learn_choice()
    c.eval("ns.Azero:Advance(2)")                                      # B: cancel
    texts_until_choice(c)
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.AzeroCraft.Skill('mining')") == 30          # kept
    c.eval("ns.Azero.save.money = 10")
    to_learn_choice()
    c.eval("ns.Azero:Advance(1)")                                      # Learn Alchemy: can't pay
    said = texts_until_choice(c)
    c.eval("T_AZ.settle()")
    assert any("can't afford" in s for s in said), said
    assert c.eval("return ns.AzeroCraft.Skill('mining')") == 30 and c.eval("return ns.AzeroCraft.Skill('alchemy')") is None
    c.eval("ns.Azero.save.money = 200")
    to_learn_choice()
    c.eval("ns.Azero:Advance(1)")
    said = texts_until_choice(c)
    c.eval("T_AZ.settle()")
    assert "You have unlearned Mining." in said and "You have learned Alchemy!" in said, said
    assert c.eval("return ns.AzeroCraft.Skill('mining')") is None and c.eval("return ns.Azero.save.money") == 150
    no_errors(w)


# 6 ---------------------------------------------------------------------------------------------------------------
@case
def the_chess_event_has_a_plinth_and_the_hall_still_fits():
    w, c = game()
    r = c.eval_py("""local H, G = ns.AzeroHideout, ns.Azero
      G:EnterMap('hideout', 17, 31, 'up', true)
      local m = G.map
      local seen, bad = {}, {}
      local chess
      for k, o in pairs(m.object) do
        if o.boss then
          if seen[k] then bad[#bad + 1] = 'twice ' .. o.x .. ',' .. o.y end
          seen[k] = true
          if o.boss.enc == 660 then chess = o end
          if o.x < 1 or o.x > m.w - 2 or m.sign[k] then bad[#bad + 1] = 'off ' .. o.x .. ',' .. o.y end
          -- reachable: an open tile beside it, above or below (the walk lane between two rows of plinths)
          local reach = false
          for _, d in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
            local n = m.key(o.x + d[1], o.y + d[2])
            if not m.solid[n] and not m.object[n] then reach = true end
          end
          if not reach then bad[#bad + 1] = 'blocked ' .. o.x .. ',' .. o.y end
        end
      end
      return { name = H.Boss(660) and H.Boss(660).name, x = chess and chess.x, y = chess and chess.y, bad = bad }""")
    assert r["name"] == "Chess Event" and r["x"] and r["bad"] == [], r
    # a Chess kill puts a trophy on it
    c.eval("""local now = GetServerTime()
      ns.db.raids.c1 = { id = 'c1', start = now - 9000, stop = now - 2000, zone = 'Karazhan', att = {},
        bosses = { { enc = 660, ts = now - 5000, roster = { 'Alice' }, dur = 400 } } }
      ns.AzeroHideout.Invalidate()""")
    assert c.eval("return ns.AzeroHideout.Trophy(660) ~= nil") is True
    no_errors(w)


# 7 ---------------------------------------------------------------------------------------------------------------
@case
def a_kill_is_not_judged_before_the_roster_is_in_and_a_guild_kill_stays_one():
    w, c = game(members=[("Bob", "MAGE", 3), ("Cid", "ROGUE", 3)])
    c.eval("""local now = GetServerTime()
      ns.db.raids.g1 = { id = 'g1', start = now - 9000, stop = now - 2000, zone = 'Karazhan', att = {},
        bosses = { { enc = 661, ts = now - 5000, roster = { 'Alice', 'Bob', 'Cid', 'Zed' }, dur = 300 } } }
      ns.db.raids.p1 = { id = 'p1', start = now - 99000, stop = now - 92000, zone = 'Karazhan', att = {},
        bosses = { { enc = 652, ts = now - 95000, roster = { 'Alice', 'Xan', 'Yob', 'Zed' }, dur = 200 } } }
      -- a kill that carries its own count of guildmates (gn) is judged by it
      ns.db.raids.n1 = { id = 'n1', start = now - 99000, stop = now - 92000, zone = 'Karazhan', att = {},
        bosses = { { enc = 653, ts = now - 95000, roster = { 'Alice', 'Bob', 'Cid', 'Zed' }, gn = 1, dur = 200 } } }
      T_REAL = { ready = ns.Guild.IsReady, inGuild = ns.Guild.IsInGuild }
      ns.Guild.IsReady = function() return false end              -- just after login: the roster isn't in yet
      ns.AzeroHideout.Invalidate()""")
    r = c.eval_py("local H = ns.AzeroHideout return { g = H.Trophy(661) ~= nil, p = H.Trophy(652) ~= nil, n = H.Trophy(653) ~= nil }")
    assert r == {"g": True, "p": True, "n": False}, r
    # the plinths in the hall look again when the roster arrives
    c.eval("ns.Azero:EnterMap('hideout', 14, 22, 'up', true)")
    tile = "for k, o in pairs(ns.Azero.map.object) do if o.boss and o.boss.enc == %d then return ns.Azero.map.over[k] end end"
    assert c.eval(tile % 652) == "plinth"
    c.eval("ns.Guild.IsReady = T_REAL.ready ns:Fire('ROSTER_UPDATED', true)")
    assert c.eval(tile % 652) == "plinthempty"
    r = c.eval_py("local H = ns.AzeroHideout H.Invalidate() return { g = H.Trophy(661) ~= nil, p = H.Trophy(652) ~= nil }")
    assert r == {"g": True, "p": False}, r
    # Bob and Cid leave the guild: the kill they made with the guild keeps its trophy
    c.eval("""ns.Guild.IsInGuild = function(self, key) return key and key:match('^Alice') ~= nil end
      ns.AzeroHideout.Invalidate()""")
    assert c.eval("return ns.AzeroHideout.Trophy(661) ~= nil") is True
    c.eval("ns.Guild.IsInGuild = T_REAL.inGuild")
    no_errors(w)


# 8 ---------------------------------------------------------------------------------------------------------------
@case
def the_statues_do_not_rebuild_the_rankings_every_frame():
    w, c = game()
    tame(c, "owlet", "kobling")
    r = c.eval_py("""local GB, H = ns.AzeroGuild, ns.AzeroHideout
      local real = GB.MySummary
      T_CALLS = 0
      GB.MySummary = function(self) T_CALLS = T_CALLS + 1 return real(self) end
      local first = GB:Ranking('tamed')
      for i = 1, 100 do for _, ch in ipairs(H.CHAMPIONS) do H.Champion(ch.cat) end end
      local same = GB:Ranking('tamed') == first
      local calls = T_CALLS
      GB:MarkDirty()
      local fresh = GB:Ranking('tamed') ~= first
      GB.MySummary = real
      return { calls = calls, same = same, fresh = fresh, champ = H.Champion('tamed').name }""")
    assert r["calls"] <= 1 and r["same"] and r["fresh"] and r["champ"] == "Alice", r
    # and after a second (the cache's age limit) it is rebuilt by itself
    c.eval("T_FIRST = ns.AzeroGuild:Ranking('tamed')")
    w.tick(1.2)
    assert c.eval("return ns.AzeroGuild:Ranking('tamed') ~= T_FIRST") is True
    no_errors(w)


# 9 ---------------------------------------------------------------------------------------------------------------
@case
def first_in_the_guild_is_not_lost_to_a_wrong_clock():
    w, cs = guild(("Alice", "Bob"))
    a, b = cs["Alice"], cs["Bob"]
    a.eval("ns.Azero:NewGame()")
    # Bob's PC clock is years behind: his claim to have completed the Bestiary first arrives first
    b.eval("ns.Comm:Send({ t = 'AZS', v = 1, c = { 1 }, done = 1000000000 }, 'GUILD', nil, 'game')")
    w.tick(0.5)
    e = stored(a, "Bob")
    now = a.eval("return GetServerTime()")
    assert e and now - 5 <= e["done"] <= now + 5, e                # counted from when it was heard of
    # Alice completes it (server time), after Bob's stamp: not first yet
    ids = a.eval_py("return ns.AzeroGuild.CompletableIds()")
    w.tick(2)
    tame(a, *ids)
    assert a.eval("return ns.Azero:Data().bestiaryDone") >= now
    assert a.eval("return ns.AzeroAch.Earned().guildfirst == nil") is True
    # a stamp from the future never wins either, and an old stored bad one is ignored
    b.eval("ns.Comm:Send({ t = 'AZS', v = 1, c = { 1 }, done = GetServerTime() + 10 * 86400 }, 'GUILD', nil, 'game')")
    w.tick(0.5)
    assert stored(a, "Bob")["done"] == e["done"], stored(a, "Bob")  # never moves later than first heard
    # the summary that would make Alice first: Bob's real stamp turns out later (re-checked on arrival)
    a.eval("local s = ns.Azero:Data().guild for k, x in pairs(s) do if x.name == 'Bob' then x.done = 999 end end")
    b.eval("ns.Comm:Send({ t = 'AZS', v = 1, c = { 1 }, done = GetServerTime() + 100 }, 'GUILD', nil, 'game')")
    w.tick(0.5)
    assert a.eval("return ns.AzeroAch.Earned().guildfirst ~= nil") is True
    no_errors(w)


# 10 --------------------------------------------------------------------------------------------------------------
@case
def the_bounty_day_holds_whatever_the_client_says_about_the_reset():
    w, c = game()
    # Tuesday 29 September 2026 12:00 UTC, the reset at 03:00 UTC (15 h away)
    t = 1790683200
    c.eval("ns.AzeroBounty.clock = %d ns.AzeroBounty.resetIn = nil T_LEFT = 15 * 3600 "
           "GetQuestResetTime = function() return T_LEFT end" % t)
    keys = []
    for left in ("14 * 3600", "16 * 3600", "0", "nil", "200000", "-5", "15 * 3600"):   # (+-1 h: summer time)
        keys.append(c.eval("T_LEFT = %s return ns.AzeroBounty.DayKey()" % left))
    assert len(set(keys)) == 1, keys
    left = c.eval("T_LEFT = 0 return ns.AzeroBounty.ResetIn()")
    assert left == 15 * 3600, left                                   # the remembered reset hour, not midnight
    # the same day from just after one reset to just before the next; the next day after it
    day = keys[0]
    c.eval("ns.AzeroBounty.clock = %d T_LEFT = 1" % (t + 15 * 3600 - 1))
    assert c.eval("return ns.AzeroBounty.DayKey()") == day
    c.eval("ns.AzeroBounty.clock = %d T_LEFT = nil" % (t + 15 * 3600 + 1))
    assert c.eval("return ns.AzeroBounty.DayKey()") == day + 24
    # a day that comes back keeps its progress (nothing paid twice)
    c.eval("ns.AzeroBounty.clock = %d T_LEFT = 15 * 3600" % t)
    c.eval("local st = ns.AzeroBounty:State() st.list[1].done = true st.list[1].got = st.list[1].n")
    c.eval("ns.AzeroBounty.clock = %d" % (t + DAY))
    assert c.eval("return ns.AzeroBounty:State().list[1].done == true") is False
    c.eval("ns.AzeroBounty.clock = %d" % t)
    assert c.eval("return ns.AzeroBounty:State().list[1].done == true") is True
    no_errors(w)


# 11 --------------------------------------------------------------------------------------------------------------
@case
def a_new_game_pays_no_bounty_or_guild_tier_again():
    w, c = game()
    c.eval("""local st = ns.AzeroBounty:State()
      st.list[1].done = true st.list[1].got = st.list[1].n st.wn = 6 st.tiers = { true }""")
    c.eval("ns.Azero:NewGame() ns.Azero.save.money = 0")
    r = c.eval_py("""local st = ns.AzeroBounty:State()
      ns.AzeroBounty:CheckTiers()
      return { done = st.list[1].done == true, wn = st.wn, t1 = st.tiers[1] == true, money = ns.Azero.save.money,
               insave = ns.Azero.save.bounty ~= nil }""")
    assert r == {"done": True, "wn": 6, "t1": True, "money": 0, "insave": False}, r
    # progress kept in the save by older versions moves over on the first read
    r = c.eval_py("""local B, G = ns.AzeroBounty, ns.Azero
      local day, week = B.DayKey(), B.WeekKey()
      G:Data().bounty = nil
      G.save.bounty = { day = day, list = { { id = 'tame', n = 2, got = 2, done = true, money = 10, item = 'potion', count = 1 } },
                        week = week, wn = 3, tiers = { true } }
      local st = B:State()
      return { got = st.list[1].got, wn = st.wn, t1 = st.tiers[1] == true, left = G.save.bounty ~= nil }""")
    assert r == {"got": 2, "wn": 3, "t1": True, "left": False}, r
    no_errors(w)


# 12 --------------------------------------------------------------------------------------------------------------
@case
def one_sound_for_a_bounty_and_one_for_a_guild_tier():
    w, c = game()
    c.eval("ns.AzeroAch.Earned().bounty1 = 1 ns.AzeroAch.Earned().guildgold = 1")   # no achievement toast in between
    c.eval("ns.Azero:Data().sfx = nil")
    n0 = c.eval("return #__MOCK.sounds")
    c.eval("""local st = ns.AzeroBounty:State()
      ns.AzeroBounty:Complete(st.list[1])""")
    sounds = c.eval_py("return __MOCK.sounds")[n0:]
    assert c.eval("return ns.AzeroAch:ToastFrame():IsShown()") is True
    assert sounds == [c.eval("return ns.AzeroSound.SFX.bounty")], sounds
    w.tick(7)
    n0 = c.eval("return #__MOCK.sounds")
    c.eval("""local B = ns.AzeroBounty
      local st = B:State()
      st.wn = B.Goal(st.week).tiers[1] st.tiers = {}
      B:CheckTiers()""")
    sounds = c.eval_py("return __MOCK.sounds")[n0:]
    assert sounds == [c.eval("return ns.AzeroSound.SFX.fanfare")], sounds
    no_errors(w)


if __name__ == "__main__":
    run_all()
