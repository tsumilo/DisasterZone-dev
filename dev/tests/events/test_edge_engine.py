"""Edge cases of the event engine (Core/EventEngine.lua) and the pieces' checks (Core/EventBlocks.lua), run straight
on ns.EventEngine:New with a fake clock and an out adapter that records what the world would see.

Covers: brackets of 3 to 33 (byes, seeds, one match per player a round), a bronze match of 3 decided by a bye, a
bracket with nobody (or one) in it ends its stage, a match still being fed can't be decided, round robin odd counts
and ties, best of / final best of / at once 1 / the no-show, a duel that starts a waiting match leaves both ready,
duels outside a match count for nothing; sign-up joins once until full or closed, going offline and back, leaving
after the sign-up closed forfeits; asks time out, go to the host and end with their match, a restored run drops
questions nobody waits for and survives a state with missing parts or a gone stage; a script that waits may loop long
(endless ones, ping-pong stages, too many scripts / timers still stop), waits stand still while paused, chat text is
cleaned and cut between letters (and only the four channels), numbers stay finite and a season grant is held to the
cap, unset values say nothing, settings of the wrong kind read as defaults; the checks see newer pieces and board
pieces inside a smart block, the diff shows stages, taken-out badges and moved scripts, the season check sees taken /
set / smart-block grants.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_edge_engine.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

# T.mk(def, n, opts): a run of n players P1..Pn (sign-up order = seed order), a fake clock (T.clock), and everything
# it says: guild chat posts in T.said ({ "GUILD", text }), "tell" lines in T.wh ({ key, text } a player), "show"
# banners in T.ann; its log in T.logs.
HELPERS = r"""
T = {}
function T.mk(def, n, opts)
  opts = opts or {}
  local names = {}
  for i = 1, n do names[i] = "P" .. i .. "-Thunderstrike" end
  T.clock = 1000
  T.said, T.wh, T.ann, T.logs = {}, {}, {}, {}
  T.out = {
    guild = function(text) T.said[#T.said + 1] = { "GUILD", text } end,
    tell = function(keys, text) for _, k in ipairs(keys) do T.wh[#T.wh + 1] = { k, text } end end,
    show = function(keys, text) T.ann[#T.ann + 1] = text end,
    log = function(kind, text) T.logs[#T.logs + 1] = kind .. ": " .. tostring(text) end,
  }
  T.run = ns.EventEngine:New(def, { id = "x", host = opts.host or names[1], signups = opts.signups or names, out = T.out,
    now = function() return T.clock end })
  T.names = names
  return T.run, names
end
function T.restore(def)
  T.run = ns.EventEngine:Restore(def, T.run:Snapshot(), { now = function() return T.clock end, out = T.out })
  return T.run
end
function T.adv(sec) for i = 1, sec do T.clock = T.clock + 1; T.run:Tick() end end
function T.errors()
  local out = {}
  for _, l in ipairs(T.logs) do if l:find("^error") then out[#out + 1] = l end end
  return out
end
function T.bk() return T.run:MainBracket() end
function T.short(k) return k and (k:gsub("%-.*", "")) or "-" end
function T.num(k) return tonumber(k:match("^P(%d+)")) end
function T.round(r)
  local bk, out = T.bk(), {}
  for _, mid in ipairs(bk.rounds[r] or {}) do
    local m = bk.m[mid]
    out[#out + 1] = T.short(m.a) .. "v" .. T.short(m.b) .. ":" .. m.st .. (m.win and ("=" .. T.short(m.win)) or "")
      .. (m.bronze and "(B)" or "")
  end
  return out
end
function T.playing()
  local bk, out = T.bk(), {}
  for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
    if bk.m[mid].st == "play" then out[#out + 1] = bk.m[mid] end
  end
  return out
end
-- plays every match out (the lower number wins every duel)
function T.playout()
  for g = 1, 400 do
    if T.run.st.phase ~= "live" then return true end
    local ms = T.playing()
    if #ms == 0 then T.adv(5) end
    for _, m in ipairs(ms) do
      if T.num(m.a) < T.num(m.b) then T.run:Duel(m.a, m.b, true) else T.run:Duel(m.b, m.a, true) end
    end
  end
  return false
end
function T.asks()
  local out = {}
  for id, a in pairs(T.run.st.asks) do
    local to = {}
    for _, k in ipairs(a.to) do to[#to + 1] = T.short(k) end
    out[#out + 1] = table.concat(to, ",") .. ": " .. a.q
  end
  table.sort(out)
  return out
end
-- the starter, seeded in sign-up order, cancelled below `least` players, sign-up of `spots`
function T.starter(least, spots)
  local d = ns.EventBlocks:Starter()
  d.blocks.b2.set.seed = "order"
  d.blocks.b1.set.spots = spots or 16
  d.scripts[2].top.n.a[1].a[2] = least or 4
  return d
end
-- a bare event: stages s1, s2, one script in s1
function T.bare(top)
  local d = ns.EventBlocks:Blank("t")
  d.scripts = { { id = "a", st = "s1", top = top } }
  return d
end
N, C, V, J, If = ns.EventBlocks.Build.N, ns.EventBlocks.Build.C, ns.EventBlocks.Build.V, ns.EventBlocks.Build.J,
  ns.EventBlocks.Build.If
S = function(...) return ns.EventBlocks:Stack(...) end
"""


def one():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    c.eval(HELPERS)
    return w, c


# ------------------------------------------------------------------------------------------------------------------
# Brackets
# ------------------------------------------------------------------------------------------------------------------

@case
def brackets_of_three_to_thirty_three_seed_and_bye_right():
    w, c = one()
    for n in (3, 5, 6, 7, 9, 12, 17, 33):
        out = c.eval_py("""
            local n = ...
            local d = T.starter(2, 40)
            d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
            local run = T.mk(d, n)
            run:Start()
            local bk = T.bk()
            local size = 2 ^ bk.last
            local byes, doubles, twice, topByes = 0, 0, {}, true
            for _, mid in ipairs(bk.rounds[1]) do
              local m = bk.m[mid]
              if m.st == "bye" then
                byes = byes + 1
                if not m.a then doubles = doubles + 1 end
                -- the byes go to the top seeds
                if T.num(m.a) > size - n then topByes = false end
              end
            end
            local done = T.playout()
            -- nobody plays two matches in one round
            for r = 1, bk.last do
              local seen = {}
              for _, mid in ipairs(bk.rounds[r]) do
                local m = bk.m[mid]
                for _, k in ipairs({ m.a or "", m.b or "" }) do
                  if k ~= "" then
                    if seen[k] then twice[#twice + 1] = r .. ":" .. k end
                    seen[k] = true
                  end
                end
              end
            end
            return { byes = byes, want = size - n, doubles = doubles, topByes = topByes, twice = twice, done = done,
              champ = T.short(bk.champ), second = T.short(bk.second), third = T.short(bk.third), err = T.errors() }""", n)
        assert out["byes"] == out["want"] and out["doubles"] == 0 and out["topByes"], (n, out)
        assert out["twice"] == [] and out["done"] and out["err"] == [], (n, out)
        assert (out["champ"], out["second"], out["third"]) == ("P1", "P2", "P3"), (n, out)
    w.assert_no_errors()


@case
def a_bronze_match_of_three_goes_to_the_semi_loser_by_a_bye():
    # was: the bye's empty side counted as its loser, so seed 1 (also in the final) played the bronze match
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2)
        d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
        local run = T.mk(d, 3)
        run:Start()
        local bk = T.bk()
        local m = T.playing()[1]
        run:Duel(m.a, m.b, true)          -- P2 beats P3 in the only semi
        local r2 = T.round(2)
        T.playout()
        return { r2 = r2, third = T.short(bk.third), champ = T.short(bk.champ), err = T.errors() }""")
    assert out["r2"] == ["P1vP2:play", "-vP3:bye=P3(B)"], out
    assert out["third"] == "P3" and out["champ"] == "P1" and out["err"] == [], out
    # four players: a real bronze match
    out = c.eval_py("""
        local d = T.starter(2)
        d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
        local run = T.mk(d, 4)
        run:Start()
        for _, m in ipairs(T.playing()) do run:Duel(m.a, m.b, true) end
        return T.round(2)""")
    assert out == ["P1vP2:play", "P4vP3:play(B)"], out
    w.assert_no_errors()


@case
def a_bracket_with_nobody_or_one_player_ends_its_stage():
    # was: no "bracket is done" for fewer than two players, so the event sat in the bracket stage for good
    w, c = one()
    for n in (0, 1):
        out = c.eval_py("""
            local run = T.mk(T.starter(0), ...)
            run:Start()
            T.adv(3)
            local bk = T.bk()
            return { phase = run.st.phase, stage = run.st.stage, champ = bk.champ or false, err = T.errors() }""", n)
        assert out == {"phase": "done", "stage": "s4", "champ": False, "err": []}, (n, out)
    # two players: one match, which is the final
    out = c.eval_py("""
        local d = T.starter(2); d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
        local run = T.mk(d, 2)
        run:Start()
        local r1 = T.round(1)
        T.playout()
        local bk = T.bk()
        return { r1 = r1, champ = T.short(bk.champ), second = T.short(bk.second), third = bk.third or false,
          phase = run.st.phase }""")
    assert out == {"r1": ["P1vP2:play"], "champ": "P1", "second": "P2", "third": False, "phase": "done"}, out
    w.assert_no_errors()


@case
def a_match_still_being_fed_cant_be_decided():
    # was: the host deciding a round 2 match whose other side wasn't known played it with nobody, and its winner lost
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2)
        local run = T.mk(d, 5)       -- P1 has a bye: round 2's first match is P1 vs (P4 or P5)
        run:Start()
        local bk = T.bk()
        local m = bk.m[bk.rounds[2][1]]
        run:BracketPlay("b2", m)
        run:BracketFinish("b2", m, m.a, false)
        run:Pump()
        return { st = m.st, a = T.short(m.a), b = m.b, elim = bk.elim and bk.elim[m.a] or false }""")
    assert out == {"st": "wait", "a": "P1", "b": False, "elim": False}, out
    w.assert_no_errors()


@case
def round_robin_odd_counts_and_ties():
    w, c = one()
    for n in (3, 5, 7):
        out = c.eval_py("""
            local d = T.starter(2)
            d.blocks.b2.set.fmt = "robin"; d.blocks.b2.set.bo = 1; d.blocks.b2.set.atonce = 8
            local run = T.mk(d, ...)
            run:Start()
            local bk = T.bk()
            local seen, dup, n = {}, 0, 0
            for r = 1, bk.last do
              local inr = {}
              for _, mid in ipairs(bk.rounds[r]) do
                local m = bk.m[mid]
                local k = m.a < m.b and m.a .. m.b or m.b .. m.a
                if seen[k] or inr[m.a] or inr[m.b] then dup = dup + 1 end
                seen[k], inr[m.a], inr[m.b] = true, true, true
                n = n + 1
              end
            end
            return { n = n, dup = dup, done = T.playout(), champ = T.short(bk.champ) }""", n)
        assert out == {"n": n * (n - 1) // 2, "dup": 0, "done": True, "champ": "P1"}, (n, out)
    # a three-way tie (each wins once): the seed decides
    out = c.eval_py("""
        local d = T.starter(2)
        d.blocks.b2.set.fmt = "robin"; d.blocks.b2.set.bo = 1; d.blocks.b2.set.atonce = 8
        local run = T.mk(d, 3)
        run:Start()
        local beats = { P1 = "P2", P2 = "P3", P3 = "P1" }
        for g = 1, 20 do
          for _, m in ipairs(T.playing()) do
            if beats[T.short(m.a)] == T.short(m.b) then run:Duel(m.a, m.b, true) else run:Duel(m.b, m.a, true) end
          end
          T.adv(2)
        end
        local bk = T.bk()
        return { T.short(bk.champ), T.short(bk.second), T.short(bk.third), run.st.phase }""")
    assert out == ["P1", "P2", "P3", "done"], out
    w.assert_no_errors()


@case
def best_of_at_once_and_the_no_show_timer():
    w, c = one()
    # best of 3, the final (and bronze) best of 5
    out = c.eval_py("""
        local d = T.starter(2)
        local run = T.mk(d, 4)
        run:Start()
        local m = T.playing()[1]
        run:Duel(m.a, m.b, true); run:Duel(m.b, m.a, true)
        local mid = { m.wa, m.wb, m.st }
        run:Duel(m.a, m.b, true)
        local m2 = T.playing()[1]
        run:Duel(m2.a, m2.b, true); run:Duel(m2.a, m2.b, true)
        local f = T.playing()[1]
        return { mid = mid, done = { m.wa, m.wb, m.st }, bo = m.bo, fbo = f.bo, final = f.final or false }""")
    assert out == {"mid": [1, 1, "play"], "done": [2, 1, "done"], "bo": 3, "fbo": 5, "final": True}, out
    # at once = 1: one match at a time, the next starts when it ends
    out = c.eval_py("""
        local d = T.starter(2); d.blocks.b2.set.atonce = 1; d.blocks.b2.set.bo = 1
        local run = T.mk(d, 8)
        run:Start()
        local before = #T.playing()
        run:Duel(T.playing()[1].a, T.playing()[1].b, true)
        return { before, #T.playing(), T.round(1)[2] }""")
    assert out == [1, 1, "P4vP5:play"], out
    # the no-show: only the one who is ready wins it; both or neither ready: the match goes on (the host decides)
    for who, want in (("one", ["done", "P1"]), ("both", ["play", "-"]), ("neither", ["play", "-"])):
        out = c.eval_py("""
            local who = ...
            local run = T.mk(T.starter(2), 4)
            run:Start()
            local m = T.playing()[1]
            if who ~= "neither" then run:SetReady(m.a) end
            if who == "both" then run:SetReady(m.b) end
            T.adv(305)
            return { m.st, T.short(m.win) }""", who)
        assert out == want, (who, out)
    w.assert_no_errors()


@case
def a_duel_that_starts_a_waiting_match_leaves_both_ready():
    # was: the duel marked both ready, then the match it started cleared them (a no-show could go the wrong way)
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2); d.blocks.b2.set.atonce = 1
        local run = T.mk(d, 8)
        run:Start()
        local bk = T.bk()
        local m = bk.m[bk.rounds[1][4]]     -- P3 vs P6, waiting (one match at a time)
        local st0 = m.st
        run:Duel(m.a, m.b, true)
        return { st0, m.st, m.wa, run.st.ready[m.a] or false, run.st.ready[m.b] or false }""")
    assert out == ["wait", "play", 1, True, True], out
    w.assert_no_errors()


@case
def duels_outside_a_match_count_for_nothing():
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2); d.blocks.b2.set.bo = 1
        local run = T.mk(d, 4)
        run:Start()
        local bk = T.bk()
        local P = T.names
        run:Duel(P[1], P[2], true)            -- two entrants, not each other's opponent
        run:Duel(P[1], "Out-Thunderstrike", true)
        local r = { T.round(1) }
        run:Duel(P[1], P[4], true)            -- P1's match
        run:Duel(P[1], P[4], true)            -- again: the match is over
        run:Duel(P[4], P[1], true)
        r[2] = T.round(1)
        return r""")
    assert out[0] == ["P1vP4:play", "P2vP3:play"], out
    assert out[1] == ["P1vP4:done=P1", "P2vP3:play"], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Sign-up and leaving
# ------------------------------------------------------------------------------------------------------------------

@case
def sign_up_joins_once_until_full_or_closed():
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2, 4); d.blocks.b1.set.closes = "host"
        local run = T.mk(d, 6, { signups = {} })
        run:Start()
        local P = T.names
        local r = { run:Join(P[1]), run:Join(P[1]), run:Join(P[2]), run:Join(P[3]), run:Join(P[4]), run:Join(P[5]) }
        r[#r + 1] = run:Leave(P[2])
        r[#r + 1] = run:Join(P[5])
        run:CloseSignup("b1"); run:Pump()
        r[#r + 1] = run:Join(P[6])
        local e = {}
        for i, k in ipairs(run.st.entrants) do e[i] = T.short(k) end
        return { r = r, e = e, stage = run.st.stage }""")
    assert out["r"] == [True, False, True, True, True, False, True, True, False], out
    assert out["e"] == ["P1", "P3", "P4", "P5"] and out["stage"] == "s2", out
    # going offline and coming back: once each, entrants only
    out = c.eval_py("""
        local d = T.bare(S(N("ev.happen", "off"), N("ch.guild", J("off ", C("player")))))
        d.scripts[2] = { id = "b", st = "*", top = S(N("ev.happen", "on"), N("ch.guild", J("on ", C("player")))) }
        local run = T.mk(d, 2)
        run:Start()
        run:SetOnline(T.names[2], false); run:SetOnline(T.names[2], false)
        run:SetOnline("Out-Thunderstrike", false)
        run:SetOnline(T.names[2], true)
        local said = {}
        for _, s in ipairs(T.said) do said[#said + 1] = s[2] end
        return said""")
    assert out == ["off P2", "on P2"], out
    w.assert_no_errors()


@case
def leaving_after_the_sign_up_closed_forfeits_the_match():
    # was: Leave did nothing once the sign-up closed (the board's "Leave the event" promises the match is lost)
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2); d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1
        local run = T.mk(d, 8)
        run:Start()
        local bk = T.bk()
        local P = T.names
        local m = bk.m[bk.rounds[1][1]]            -- P1 vs P8, being played
        local left = run:Leave(P[1])
        local r = { left = left, m = { m.st, T.short(m.win), m.wo or false } }
        -- P2 wins round 1, then leaves while waiting for round 2: round 2 is a walkover
        local m3 = bk.m[bk.rounds[1][3]]
        run:Duel(P[2], P[7], true)
        run:Leave(P[2])
        for _, x in ipairs(T.playing()) do run:Duel(x.a, x.b, true) end
        T.adv(2)
        r.r2 = T.round(2)
        r.inEvent = { P1 = false, P2 = false }
        for _, k in ipairs(run.st.entrants) do if k == P[1] or k == P[2] then r.inEvent[T.short(k)] = true end end
        r.again = run:Leave(P[1])
        r.err = T.errors()
        return r""")
    assert out["left"] is True and out["m"] == ["done", "P8", True], out
    assert out["r2"][1] == "P2vP3:done=P3", out
    assert out["inEvent"] == {"P1": False, "P2": False} and out["again"] is False and out["err"] == [], out
    # no sign-up block at all: leaving still takes the player out
    out = c.eval_py("""
        local d = T.starter(2)
        d.blocks.b1 = nil
        d.blocks.b2.stage = "s1"
        local run = T.mk(d, 4)
        run:Start()
        local ok = run:Leave(T.names[4])
        return { ok, #run.st.entrants, T.round(1)[1] }""")
    assert out == [True, 3, "P1vP4:done=P1"], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Asks (who won)
# ------------------------------------------------------------------------------------------------------------------

@case
def asks_time_out_go_to_the_host_and_end_with_their_match():
    w, c = one()
    base = """
        local run = T.mk(T.starter(2), 4, { host = "Host-Thunderstrike" })
        run:Start()
        local m = T.playing()[1]
        run:Duel(m.a, m.b, false)        -- not agreed: both are asked
        local id = next(run.st.asks)
    """
    # nobody answers: after a minute the host is asked; nobody there either: the game doesn't count
    out = c.eval_py(base + """
        local r = { T.asks() }
        T.adv(61); r[2] = T.asks()
        T.adv(61); r[3] = T.asks()
        r[4] = { m.wa, m.wb }
        return r""")
    assert out == [["P1,P4: Who won game 1?"], ["Host: Who won game 1?"], [], [0, 0]], out
    # only one answers: that answer counts after the minute
    out = c.eval_py(base + """
        run:Answer(id, m.a, m.a)
        T.adv(61)
        return { T.asks(), m.wa, m.wb }""")
    assert out == [[], 1, 0], out
    # they disagree: the host decides
    out = c.eval_py(base + """
        run:Answer(id, m.a, m.a); run:Answer(id, m.b, m.b)
        local r = { T.asks() }
        run:Answer(next(run.st.asks), "Host-Thunderstrike", m.b)
        r[2] = { m.wa, m.wb }
        return r""")
    assert out == [["Host: Who won game 1?"], [0, 1]], out
    # the host decides the match meanwhile: the question goes at once and is never passed on
    # (was: it stayed up, and the players' answers then asked the host about a match that was over)
    out = c.eval_py(base + """
        run:BracketFinish("b2", m, m.b); run:Pump()
        local r = { T.asks() }
        run:Answer(id, m.a, m.a); run:Answer(id, m.b, m.b)
        T.adv(2)
        r[2] = T.asks()
        T.adv(130)
        r[3] = T.asks()
        r[4] = { m.wa, m.wb, m.st, T.short(m.win) }
        local n = 0 for _ in pairs(run.threads) do n = n + 1 end
        r[5] = n
        return r""")
    assert out == [[], [], [], [0, 0, "done", "P4"], 0], out
    w.assert_no_errors()


@case
def a_restored_run_drops_questions_nobody_waits_for():
    # was: after a /reload or a takeover the question stayed on the players' screens for good and answers did nothing
    w, c = one()
    out = c.eval_py("""
        local d = T.starter(2)
        local run = T.mk(d, 4)
        run:Start()
        local m = T.playing()[1]
        run:Duel(m.a, m.b, false)
        local before = T.asks()
        run = T.restore(d)
        local after = T.asks()
        local m2 = T.bk().m[m.id]
        -- the match goes on: the next duels count
        run:Duel(m2.a, m2.b, true); run:Duel(m2.a, m2.b, true)
        return { before, after, m2.st, T.short(m2.win), run.st.askSeq }""")
    assert out == [["P1,P4: Who won game 1?"], [], "done", "P1", 1], out
    w.assert_no_errors()


@case
def a_restore_survives_a_state_with_missing_parts():
    # was: a state without its timers / ready / asks tables (a broken message) errored on every tick of the new host
    w, c = one()
    out = c.eval_py("""
        local d = ns.EventBlocks:Starter()
        local st = { id = "x", phase = "live", seq = 3, entrants = { "P1-Thunderstrike" }, blocks = {}, stage = "s1",
          timers = { { n = "t" }, "junk" } }
        local run = ns.EventEngine:Restore(d, st, { now = function() return 5000 end, out = {} })
        local errs = {}
        for _, f in ipairs({
          function() run:Tick() end,
          function() run:Join("P2-Thunderstrike") end,
          function() run:Duel("P1-Thunderstrike", "P2-Thunderstrike", true) end,
          function() run:SetReady("P1-Thunderstrike") end,
          function() run:Answer(1, "P1-Thunderstrike", "P1-Thunderstrike") end,
          function() run:Leave("P2-Thunderstrike") end,
          function() run:GoStage("s2"); run:Pump() end,
          function() run:End() end,
        }) do
          local ok, e = pcall(f)
          if not ok then errs[#errs + 1] = tostring(e) end
        end
        return { errs = errs, timers = #run.st.timers, phase = run.st.phase }""")
    assert out == {"errs": [], "timers": 0, "phase": "done"}, out
    # a restore goes on with the timers it had (a no-show running out on the new host)
    out = c.eval_py("""
        local d = T.starter(2)
        local run = T.mk(d, 4)
        run:Start()
        local m = T.playing()[1]
        run:SetReady(m.a)
        T.adv(100)
        run = T.restore(d)
        T.adv(210)
        local m2 = T.bk().m[m.id]
        return { m2.st, T.short(m2.win) }""")
    assert out == ["done", "P1"], out
    # onto a def whose stage is gone: no error, the next stage ends it
    out = c.eval_py("""
        local d = T.starter(2)
        T.mk(d, 4):Start()
        local d2 = ns.EventBlocks.Copy(d)
        table.remove(d2.stages, 2)
        local run = T.restore(d2)
        T.adv(400)
        run:NextStage(); run:Pump()
        return { run.st.phase, T.errors() }""")
    assert out == ["done", []], out
    w.assert_no_errors()


@case
def values_unset_or_of_the_wrong_kind_say_nothing():
    w, c = one()
    out = c.eval_py("""
        local each = N("lo.each", N("su.list", "zz")); each.c1 = N("ch.guild", "each")
        local d = T.bare(S(N("ev.start"),
          N("ch.guild", J("a", V("nope"), "b", N("bk.champ", "b9"), "c", C("winner"), "d")),
          N("lo.vset", "x", 7),
          N("pt.badge", "champ", V("x")),
          N("ch.tell", V("x"), "hi"),
          N("pt.add", 5, "Wins", V("nope")),
          N("ch.guild", J("x=", V("x"), " seed=", N("pl.seed", -3))),
          each))
        d.vars = { { n = "x", t = "player" } }
        d.badges = { champ = { n = "C" } }
        local run = T.mk(d, 2, { signups = {} })
        run:Start()
        local said = {}
        for _, s in ipairs(T.said) do said[#said + 1] = s[2] end
        return { said = said, wh = #T.wh, awards = #run.st.awards, err = T.errors() }""")
    assert out == {"said": ["abcd", "x=7 seed="], "wh": 0, "awards": 0, "err": []}, out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Scripts
# ------------------------------------------------------------------------------------------------------------------

@case
def a_script_that_waits_may_loop_long_and_endless_ones_stop():
    # was: the piece count never went back to 0 at a wait, so a long loop that waits was stopped as "endless"
    w, c = one()
    out = c.eval_py("""
        local inner = N("lo.rep", 30); inner.c1 = N("tm.wait", 0)
        local outer = N("lo.rep", 100); outer.c1 = inner
        local run = T.mk(T.bare(S(N("ev.start"), outer, N("ch.guild", "done"))), 2)
        run:Start()
        T.adv(3200)
        return { #T.said, T.errors() }""")
    assert out == [1, []], out
    # no wait: stopped after STEP_LIMIT pieces (the rest of the script never runs)
    out = c.eval_py("""
        local a = N("lo.rep", 100); local b = N("lo.rep", 100); b.c1 = N("pt.add", 1, "Wins", N("pl.host")); a.c1 = b
        local run = T.mk(T.bare(S(N("ev.start"), a, N("ch.guild", "after"))), 2)
        run:Start()
        return { #T.said, #T.errors(), run:GetStat("Wins", run.st.host) < 2000 }""")
    assert out == [0, 1, True], out
    # going to its own stage on start: stopped by the queue limit, the event stays live
    out = c.eval_py("""
        local run = T.mk(T.bare(S(N("ev.start"), N("sg.go", "s1"))), 2)
        run:Start()
        return { run.st.phase, #T.errors(), #run.queue }""")
    assert out == ["live", 1, 0], out
    # too many scripts at once: the rest are skipped
    out = c.eval_py("""
        local run = T.mk(T.bare(S(N("ev.happen", "duel"), N("tm.wait", 100))), 2)
        run:Start()
        for i = 1, 70 do run:Duel(T.names[1], T.names[2]) end
        local n = 0 for _ in pairs(run.threads) do n = n + 1 end
        return n""")
    assert out == 60, out
    # too many timers: the oldest go
    out = c.eval_py("""
        local each = N("lo.rep", 100)
        each.c1 = N("tm.start", 60, J("t", N("lo.rand", 1, 1000000)))
        local run = T.mk(T.bare(S(N("ev.start"), each)), 2)
        run:Start()
        return { #run.st.timers, #T.errors() }""")
    assert out == [64, 0], out
    # ending while scripts wait: they never come back; going to a stage that's gone does nothing
    out = c.eval_py("""
        local d = T.bare(S(N("ev.start"), N("tm.wait", 30), N("ch.guild", "late")))
        d.scripts[2] = { id = "b", st = "s1", top = S(N("ev.start"), N("tm.wait", 5), N("sg.end")) }
        d.scripts[3] = { id = "c", st = "s1", top = S(N("ev.start"), N("sg.go", "zz")) }
        local run = T.mk(d, 2)
        run:Start()
        local st = run.st.stage
        T.adv(40)
        return { st, #T.said, run.st.phase }""")
    assert out == ["s1", 0, "done"], out
    w.assert_no_errors()


@case
def waits_stand_still_while_the_host_pauses():
    # was: an answer (or a duel) during a pause woke scripts whose wait ran out in the pause
    w, c = one()
    out = c.eval_py("""
        local run = T.mk(T.bare(S(N("ev.start"), N("tm.wait", 10), N("ch.guild", "go"))), 2)
        run:Start()
        run.st.paused = T.clock
        T.clock = T.clock + 30
        run:Resume()
        local during = #T.said
        run.st.paused = nil
        run:Resume()
        return { during, #T.said }""")
    assert out == [0, 1], out
    w.assert_no_errors()


@case
def chat_text_is_cleaned_cut_between_letters_and_said_in_known_channels():
    # was: "|" codes and line breaks went to chat as typed, long text was cut mid-letter by the sender, any channel went
    # (part 1's "say in {channel}" is "post in guild chat" now, or "show" for Raid / Party / Say: its old pieces are
    # turned into those when the event is loaded, so a channel it never knew still only reaches guild chat)
    w, c = one()
    out = c.eval_py("""
        local long = string.rep("a", 249) .. string.rep("\\195\\169", 10)
        local d = T.bare(S(N("ev.start"),
          N("ch.guild", "a|cffff0000red|r\\nline2"),
          N("ch.guild", long),
          { k = "ch.say", a = { "loud", "YELL" } },
          { k = "ch.say", a = { "secret", "OFFICER" } },
          { k = "ch.say", a = { "in the raid", "RAID" } },
          N("ch.guild", "|\\n"),
          N("ch.tell", N("pl.host"), "hi|r\\nthere"),
          N("ch.show", N("pl.all"), "warn|cff\\n"),
          N("ch.moment", string.rep("\\195\\169", 150)),
          N("sg.cancel", "why|r\\n" .. string.rep("b", 100))))
        local run = T.mk(d, 2)
        run:Start()
        local said = {}
        for _, s in ipairs(T.said) do said[#said + 1] = s[1] .. ":" .. (#s[2] > 40 and #s[2] or s[2]) end
        local mom = run.st.moments[1].text
        return { said = said, wh = T.wh[1][2], ann = T.ann, mom = #mom, momTail = mom:byte(#mom),
          reason = #run.st.reason, phase = run.st.phase }""")
    # 249 a + "é": 251 bytes, the cut goes before the é (never half of it)
    assert out["said"] == ["GUILD:acffff0000redr line2", "GUILD:249", "GUILD:loud", "GUILD:secret"], out
    assert out["wh"] == "hir there" and out["ann"] == ["in the raid", "warncff "], out
    assert out["mom"] == 200 and out["momTail"] == 0xA9, out
    assert out["reason"] == 80 and out["phase"] == "cancelled", out
    w.assert_no_errors()


@case
def numbers_stay_finite_and_a_season_grant_is_held_to_the_cap():
    # was: 1e308 + 1e308 gave "inf" (and inf - inf "nan") in chat and points; a worked-out grant passed any cap
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local huge = N("lo.add", 1e308, 1e308)
        local d = T.bare(S(N("ev.start"),
          N("pt.add", N("lo.sub", huge, huge), "Wins", N("pl.host")),
          N("pt.add", huge, "Laps", N("pl.host")),
          N("pt.add", N("lo.add", 4000, 1000), B.SEASON, N("pl.host")),
          N("pt.add", -5000, B.SEASON, "P2-Thunderstrike"),
          N("pt.set", B.SEASON, N("pl.rand"), 5000),
          N("pt.add", 2.5, "Points", N("pl.host")),
          N("ch.guild", J("w=", N("pt.get", N("pl.host"), "Wins"), " l=", N("pt.get", N("pl.host"), "Laps")))))
        local run = T.mk(d, 2)
        run:Start()
        local res = run:Result()
        local pts = {}
        for k, n in pairs(res.points) do pts[T.short(k)] = n end
        local log
        for _, l in ipairs(T.logs) do if l:find("Points") then log = l end end
        return { said = T.said[1][2], pts = pts, log = log, err = T.errors() }""")
    assert out["said"] == "w=0 l=1000000000", out
    assert out["pts"] == {"P1": 100, "P2": 100} or out["pts"] == {"P1": 100, "P2": -100}, out
    assert out["log"] == "points: P1 +2.5 Points" and out["err"] == [], out
    w.assert_no_errors()


@case
def settings_of_the_wrong_kind_read_as_defaults():
    # was: an event from the wire with spots = "x" or true broke joining, closing and its page; at once = 0 never
    # started a match
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local out = {}
        for _, set in ipairs({ { spots = "x" }, { spots = true }, { spots = 0 }, { spots = 99 }, { atonce = 0 },
                               { bo = 0 }, { bo = "x" }, { noshow = -5 }, { bronze = "no" }, { fmt = "swiss" } }) do
          local d = T.starter(2)
          d.blocks.b1.set.closes = "host"
          local k, v = next(set)
          if k == "spots" then d.blocks.b1.set[k] = v else d.blocks.b2.set[k] = v end
          local okD = pcall(B.Describe, B, d)
          local run = T.mk(d, 4, { signups = {} })
          local ok, e = pcall(function()
            run:Start()
            for i = 1, 4 do run:Join(T.names[i]) end
            run:CloseSignup("b1"); run:Pump()
          end)
          local blk = k == "spots" and d.blocks.b1 or d.blocks.b2
          out[#out + 1] = k .. "=" .. tostring(v) .. ":" .. tostring(ok and okD) .. ":" .. tostring(B:SmartSetting(blk, k))
            .. ":" .. #T.playing() .. ":" .. #T.errors()
        end
        return out""")
    assert out == ["spots=x:true:16:2:0", "spots=true:true:16:2:0", "spots=0:true:2:1:0", "spots=99:true:40:2:0",
                   "atonce=0:true:2:2:0", "bo=0:true:3:2:0", "bo=x:true:3:2:0", "noshow=-5:true:300:2:0",
                   "bronze=no:true:true:2:0", "fmt=swiss:true:single:2:0"], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Checks, diff, season check (Core/EventBlocks.lua)
# ------------------------------------------------------------------------------------------------------------------

@case
def the_checks_see_newer_pieces_and_board_pieces_inside_a_smart_block():
    # was: a script topped by a newer version's piece, or a board "when" piece inside the bracket, never ran and
    # nothing said so
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local function texts(d) local o = {} for _, p in ipairs(B:Problems(d)) do o[#o + 1] = (p.script or "-") .. ": " .. p.text end return o end
        local r = {}
        local d = B:Starter(); d.scripts[#d.scripts + 1] = { id = "n1", st = "s1", top = { k = "ev.newhat", a = {}, n = N("ch.guild", "x") } }
        r.newHat = texts(d)
        d = B:Starter(); d.scripts[1].top.n.n = { k = "zz.new", a = {} }
        r.newPiece = texts(d)
        d = B:Starter(); d.blocks.b2.inner = B:BracketInner()
        r.ownCopy = texts(d)
        table.insert(d.blocks.b2.inner, { id = "i9", st = "*", top = S(N("ev.start"), N("ch.guild", "x")) })
        r.boardHat = texts(d)
        -- (and it really never runs there)
        local run = T.mk(d, 4)
        run:Start()
        local ran = false
        for _, s in ipairs(T.said) do if s[2] == "x" then ran = true end end
        r.ran = ran
        d = B:Starter(); d.scripts[1].top.n.n = N("bk.gwin", C("player"))
        r.innerOutside = texts(d)
        d = B:Starter(); d.blocks.b2.stage = "gone"
        d.scripts[#d.scripts + 1] = { id = "e1", st = "s1" }
        d.scripts[#d.scripts + 1] = { id = "e2", st = "s1", top = N("ch.guild", "x") }
        r.goneAndEmpty = texts(d)
        return r""")
    assert out["newHat"] == ["n1: This piece is from a newer version of DisasterZone."], out
    assert out["newPiece"] == ["c1: This piece is from a newer version of DisasterZone."], out
    assert out["ownCopy"] == [], out
    assert out["boardHat"] == ["b2/i9: This piece only works outside the smart block."] and out["ran"] is False, out
    assert out["innerOutside"] == ["c1: This piece only works inside its smart block."], out
    assert out["goneAndEmpty"] == ["-: The stage of Matches is gone."], out
    w.assert_no_errors()


@case
def the_diff_shows_stages_taken_out_badges_and_moved_scripts():
    # was: stages and taken-out badges never showed, and a script moved to another stage looked the same
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local function show(ch) local o = {} for _, x in ipairs(ch) do o[#o + 1] = x.kind .. "|" .. tostring(x.stage) .. "|" .. (x.text or x.piece.k) end table.sort(o) return o end
        local a = B:Starter()
        local r = {}
        local b = B.Copy(a); b.badges.upset = nil
        r.badge = show((B:Diff(a, b)))
        b = B.Copy(a); b.stages[#b.stages + 1] = { id = "s5", name = "Party" }; b.stages[2].name = "Cup"
        r.stages = show((B:Diff(a, b)))
        b = B.Copy(a); table.remove(b.stages, 3)
        r.gone = show((B:Diff(a, b)))
        b = B.Copy(a); b.stages[1], b.stages[2] = b.stages[2], b.stages[1]
        r.order = show((B:Diff(a, b)))
        b = B.Copy(a); b.scripts[1].st = "*"
        r.moved = show((B:Diff(a, b)))
        local x, same = B:Diff(a, B.Copy(a))
        r.none = { #x, same }
        return r""")
    assert out["badge"] == ["del|nil|Badge taken out: Giant slayer"], out
    assert out["stages"] == ["add|Party|New stage", "chg|Cup|Stage renamed (was Bracket)"], out
    assert out["gone"] == ["del|Finals|Stage taken out"], out
    assert out["order"] == ["chg|nil|The stages are in a new order"], out
    assert out["moved"] == ["chg|Always|Moved here from Sign-up: when someone joins Sign-up"], out
    assert out["none"] == [0, 38], out
    w.assert_no_errors()


@case
def the_season_check_sees_taken_set_and_smart_block_grants():
    # was: only typed "add" grants of the event's own scripts counted: -5000, "set ... to 5000" and a 5000 inside the
    # bracket passed the review's cap
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local r = {}
        local d = B:Starter(); r.starter = B:MaxSeasonGrant(d)
        d = B:Starter(); d.scripts[4].top.n.a[1] = -5000; r.taken = B:MaxSeasonGrant(d)
        d = B:Starter(); d.scripts[1].top.n.n = N("pt.set", B.SEASON, C("player"), 5000); r.set = B:MaxSeasonGrant(d)
        d = B:Starter(); d.blocks.b2.inner = B:BracketInner()
        d.blocks.b2.inner[2].top.n.n = N("pt.add", 5000, B.SEASON, C("player"))
        r.inner = B:MaxSeasonGrant(d)
        d = B:Starter(); d.scripts[4].top.n.a[1] = N("lo.add", 4000, 1000); r.worked = B:MaxSeasonGrant(d)
        return r""")
    assert out == {"starter": 50, "taken": 5000, "set": 5000, "inner": 5000, "worked": 50}, out
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
