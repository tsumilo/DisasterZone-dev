"""Karazhan Chess (Games/Chess/): the laws, Medivh at the board, his cheats, guild games over whispers, the ladder,
the panel and the Gamesman's Hall in 3D.

Covers: move generation counts the standard perft numbers exactly (start, "Kiwipete" and four more positions);
notation (castling, promotion, mate, disambiguation) and every way a game ends; Medivh finds mates and never plays
an illegal move through a whole game at each strength, thinking in slices; his cheats keep their fair limits on
many positions (no check given, a move left, kings untouched), the fire flares after two of your moves (not a piece
whose loss would bare your king), the Hand of Medivh lets pieces step any way for four of his moves; a game with
cheats replays the same after a reload; guild games: invite / accept / moves both ways on the game prefix, the
same position on both clients, a move made while the opponent is offline reaches them when they log in, resigning,
a draw by agreement, illegal or out-of-turn moves from the wire are refused; the ladder: results go round the
guild, everyone works out the same ratings, someone offline catches up through the digest on login; the panel: the
lobby, a game opened from it, a click on a piece then its square plays the move, Medivh answers, promotion asks;
the 3D board (rooms loaded): all 64 squares on the room's floor, picking, a capture animates and Medivh waits for
it; the hub's poster.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_chess.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

HELPERS = r"""
T_CH = {}
local R, C = ns.ChessRules, ns.Chess
function T_CH.perft(fen, d) return R.Perft(R.FromFEN(fen), d) end
function T_CH.play(g, list)
  for mv in list:gmatch('%S+') do
    local ok, why = C:Play(g, mv)
    if not ok then return mv .. ':' .. tostring(why) end
  end
  return true
end
-- plays a game against Medivh with the first legal move (sorted by text, so it replays the same) until it ends
-- or n moves of mine; Medivh answers at once
function T_CH.auto(g, n)
  for _ = 1, n do
    if g.status ~= 'active' then break end
    if C:MyTurn(g) then
      local pos = C:Position(g)
      local moves = R.Legal(pos)
      local texts = {}
      for i, m in ipairs(moves) do texts[i] = R.MoveText(m) end
      table.sort(texts)
      local pick = texts[(#g.moves * 7) % #texts + 1]
      assert(C:Play(g, pick))
    end
    if g.status == 'active' and not C:MyTurn(g) then assert(C:FinishThinking(g), 'Medivh was not thinking') end
  end
end
"""

KIWI = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"


def boot(name="Alice"):
    w, c = solo(name)
    c.world = w
    c.eval(HELPERS)
    return w, c


@case
def move_generation_counts_the_standard_perft_numbers():
    w, c = boot()
    cases = [
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 3, 8902),
        (KIWI, 2, 2039),
        ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 3, 2812),
        ("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 3, 9467),
        ("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 2, 1486),
        ("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", 2, 2079),
    ]
    for fen, d, want in cases:
        got = c.eval("return T_CH.perft(...)", fen, d)
        assert got == want, (fen, d, got, want)
    # FEN goes out the way it came in
    assert c.eval("return ns.ChessRules.ToFEN(ns.ChessRules.FromFEN(...))", KIWI) == KIWI
    no_errors(w)


@case
def notation_and_every_way_a_game_ends():
    w, c = boot()
    san = lambda fen, mv: c.eval("local R = ns.ChessRules local p = R.FromFEN(...) "
                                 "return R.SAN(p, R.ParseMove(p, select(2, ...)))", fen, mv)
    assert san(KIWI, "e1g1") == "O-O"
    assert san(KIWI, "e1c1") == "O-O-O"
    assert san(KIWI, "e5f7") == "Nxf7"
    assert san("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7a8q") == "a8=Q+"
    assert san("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", "a1a8") == "Ra8#"
    assert san("4k3/8/8/8/8/8/8/R4RK1 w - - 0 1", "a1d1") == "Rad1"       # two rooks can go: the file says which
    out = lambda fen: c.eval_py("local R = ns.ChessRules local a, b = R.Outcome(R.FromFEN(...)) return { a, b }", fen)
    assert out("R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1") == ["1-0", "checkmate"]
    assert out("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1") == ["1/2-1/2", "stalemate"]
    assert out("8/8/4k3/8/8/3NK3/8/8 w - - 0 1") == ["1/2-1/2", "material"]
    assert out("8/8/4k3/8/8/3RK3/8/8 w - - 100 80") == ["1/2-1/2", "fifty"]
    # repetition: a knight dance against Medivh is a draw the third time round
    c.eval("T_CH.g = ns.Chess:NewAIGame(1, 'magus', false) "
           "T_CH.g.moves = { 'g1f3', 'g8f6', 'f3g1', 'f6g8', 'g1f3', 'g8f6', 'f3g1', 'f6g8' }")
    assert c.eval_py("local _, info = ns.Chess:Position(T_CH.g) return { ns.ChessRules.Outcome(ns.Chess:Position(T_CH.g), info.seen) }") == ["1/2-1/2", "repetition"]
    no_errors(w)


@case
def medivh_finds_mate_and_plays_whole_games_legally():
    w, c = boot()
    for st in ("apprentice", "magus", "guardian"):
        mv = c.eval("local R = ns.ChessRules local m = ns.ChessAI.Think(R.FromFEN(...), select(2, ...)) "
                    "return R.MoveText(m)", "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", st)
        assert mv == "a1a8", (st, mv)
    # thinking in slices: a step of a few ms comes back unfinished, the job ends with a legal move
    c.eval("local R = ns.ChessRules T_CH.job = ns.ChessAI.Start(R.FromFEN(...), 'guardian', nil, 3)", KIWI)
    first = c.eval("return (T_CH.job:Step(1))")
    assert first is False
    mv = c.eval("local d, m for i = 1, 100000 do d, m = T_CH.job:Step(50) if d then break end end "
                "return ns.ChessRules.MoveText(m)")
    legal = c.eval_py("local R = ns.ChessRules local out = {} for _, m in ipairs(R.Legal(R.FromFEN(...))) do "
                      "out[#out + 1] = R.MoveText(m) end return out", KIWI)
    assert mv in legal, mv
    # whole games: every move of his is legal (Play would refuse it), the game ends or goes on cleanly
    for st, color in (("apprentice", 1), ("magus", -1)):
        c.eval("T_CH.g = ns.Chess:NewAIGame(%d, %r, false)" % (color, st))
        c.eval("if not ns.Chess:MyTurn(T_CH.g) then ns.Chess:FinishThinking(T_CH.g) end")
        c.eval("T_CH.auto(T_CH.g, 30)")
        n = c.eval("return #T_CH.g.moves")
        assert n >= 20 or c.eval("return T_CH.g.status") == "over", n
        assert c.eval("local _, info = ns.Chess:Position(T_CH.g) return info.broken") is None
    no_errors(w)


@case
def cheats_keep_their_fair_limits():
    w, c = boot()
    # many positions from games: every cheat Medivh can choose leaves the player out of check (unless already in
    # it), with a legal move, kings untouched and nothing burning under a king
    bad = c.eval_py(r"""
      local R, C, AI = ns.ChessRules, ns.ChessCheats, ns.ChessAI
      local rng = AI.Rng(11)
      local bad = {}
      local fens = { R.START, ...,
        'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R b KQkq - 0 5',
        '3qk3/8/8/8/8/8/8/3QK3 b - - 0 1', '4k3/8/8/8/8/8/3PPP2/3QKB2 b - - 0 1' }
      for _, fen in ipairs(fens) do
        for medivh = -1, 1, 2 do
          local pos = R.FromFEN(fen)
          pos.side = -medivh                      -- (his move was just made: the player's turn)
          for k = 1, 25 do
            local work = R.Copy(pos)
            local wasCheck = R.InCheck(work, -medivh)
            local ev = C.Choose(work, medivh, rng, { { p = 2, sq = R.ParseSquare('f6') }, { p = 5, sq = R.ParseSquare('d4') } })
            if ev then
              C.Apply(work, ev, medivh)
              if not wasCheck and R.InCheck(work, -medivh) then bad[#bad + 1] = 'check ' .. fen .. ' ' .. ev.k end
              if not R.HasMove(work) then bad[#bad + 1] = 'no move ' .. fen .. ' ' .. ev.k end
              for sq in pairs(work.fire or {}) do
                if math.abs(work.b[sq]) == 6 then bad[#bad + 1] = 'fire on a king' end
                if work.b[sq] ~= 0 and (work.b[sq] > 0) == (medivh > 0) then bad[#bad + 1] = 'fire under his own' end
              end
              for sq in pairs(work.hand or {}) do
                if math.abs(work.b[sq]) == 6 then bad[#bad + 1] = 'hand on a king' end
                if (work.b[sq] > 0) ~= (medivh > 0) then bad[#bad + 1] = 'hand on yours' end
              end
              if ev.k == 'fire' and #ev.sq > C.FIRE_MAX then bad[#bad + 1] = 'too much fire' end
              if ev.k == 'hand' and (#ev.sq < 1 or #ev.sq > C.HAND_MAX) then bad[#bad + 1] = 'hand count' end
            end
          end
        end
      end
      return bad
    """, KIWI)
    assert bad == [], bad[:10]
    no_errors(w)


@case
def the_fire_flares_after_two_moves_and_the_hand_steps_any_way():
    w, c = boot()
    got = c.eval_py(r"""
      local R, C = ns.ChessRules, ns.ChessCheats
      -- Medivh plays black; fire under the white knight on c3 and the bishop on d2 (pinned by a5 to e1)
      local pos = R.FromFEN('4k3/8/8/b7/8/2N5/3B4/4K3 w - - 0 1')
      C.Apply(pos, { k = 'fire', sq = { 'c3', 'd2' } }, -1)
      local out = {}
      -- nobody may enter a burning square; pieces in it may leave
      local intoFire = false
      for _, m in ipairs(R.Legal(pos)) do
        local to = R.SquareName(R.To(m))
        if to == 'c3' or to == 'd2' then intoFire = true end
      end
      out.intoFire = intoFire
      R.Make(pos, R.ParseMove(pos, 'e1f2'))     -- your first move: the king steps aside, the fire burns on
      out.after1 = #C.Tick(pos, 1, -1)
      R.Make(pos, R.ParseMove(pos, 'a5b6'))     -- his
      C.Tick(pos, -1, -1)
      R.Make(pos, R.ParseMove(pos, 'f2g3'))     -- your second: it flares
      local burned = C.Tick(pos, 1, -1)
      out.burned = {}
      for _, b in ipairs(burned) do out.burned[#out.burned + 1] = R.SquareName(b.sq) end
      out.fireLeft = pos.fire ~= nil
      -- the Hand of Medivh: his knight also steps one square any way, for 4 of his moves
      local p2 = R.FromFEN('4k3/8/8/3n4/8/8/8/4K3 b - - 0 1')
      C.Apply(p2, { k = 'hand', sq = { 'd5' } }, -1)
      local steps = {}
      for _, m in ipairs(R.Legal(p2)) do
        if R.SquareName(R.From(m)) == 'd5' and R.Flag(m) == 4 then steps[#steps + 1] = R.SquareName(R.To(m)) end
      end
      table.sort(steps)
      out.steps = steps
      -- the mark moves with the piece (a step: d5 to d4) and ends after his 4th move
      R.Make(p2, R.ParseMove(p2, 'd5d4'))
      out.handOn = p2.hand and p2.hand[R.ParseSquare('d4')] and 'd4' or nil
      local life = 1
      C.Tick(p2, -1, -1)
      while p2.hand and life < 20 do
        life = life + 1
        C.Tick(p2, -1, -1)
      end
      out.life = life
      return out
    """)
    assert got["intoFire"] is False, got
    assert got["after1"] == 0, got
    # the knight on c3 burns; the bishop on d2 shielded the king on e1 - but the king left, so it burns too
    assert sorted(got["burned"]) == ["c3", "d2"], got
    assert got["fireLeft"] is False, got
    assert got["steps"] == ["c4", "c5", "c6", "d4", "d6", "e4", "e5", "e6"], got
    assert got["handOn"] == "d4" and got["life"] == 4, got
    no_errors(w)


@case
def a_pinned_piece_in_the_fire_survives_the_flare():
    w, c = boot()
    burned = c.eval_py(r"""
      local R, C = ns.ChessRules, ns.ChessCheats
      local pos = R.FromFEN('4k3/8/8/b7/8/8/3B4/4K3 w - - 0 1')   -- the bishop on d2 stands between a5 and e1
      C.Apply(pos, { k = 'fire', sq = { 'd2' } }, -1)
      pos.fire[R.ParseSquare('d2')] = 1
      R.Make(pos, R.ParseMove(pos, 'e1f1'))      -- the king leaves the diagonal: d2 may burn
      return #C.Tick(pos, 1, -1)
    """)
    assert burned == 1
    kept = c.eval_py(r"""
      local R, C = ns.ChessRules, ns.ChessCheats
      local pos = R.FromFEN('4k3/8/8/b7/8/8/3B4/4K2R w - - 0 1')
      C.Apply(pos, { k = 'fire', sq = { 'd2' } }, -1)
      pos.fire[R.ParseSquare('d2')] = 1
      R.Make(pos, R.ParseMove(pos, 'h1h2'))      -- the king still on e1: losing d2 would bare it
      local b = C.Tick(pos, 1, -1)
      return { #b, pos.b[R.ParseSquare('d2')] }
    """)
    assert kept == [0, 3], kept
    no_errors(w)


@case
def a_game_with_cheats_replays_the_same_after_a_reload():
    w, c = boot()
    c.eval("ns.ChessCheats.EVERY_MIN, ns.ChessCheats.EVERY_MAX = 2, 3")
    c.eval("T_CH.g = ns.Chess:NewAIGame(1, 'apprentice', true)")
    c.eval("T_CH.auto(T_CH.g, 24)")
    events = c.eval("return #T_CH.g.events")
    assert events >= 3, events
    kinds = set(c.eval_py("local o = {} for i, e in ipairs(T_CH.g.events) do o[i] = e.k end return o"))
    before = c.eval("return ns.ChessRules.ToFEN(ns.Chess:Position(T_CH.g), false)")
    gid = c.eval("return T_CH.g.id")
    c.relog()
    w.tick(2)
    after = c.eval("return ns.ChessRules.ToFEN(ns.Chess:Position(ns.Chess:Get(...)), false)", gid)
    assert after == before, (before, after)
    assert kinds, kinds
    no_errors(w)


def pair():
    w = World()
    a, b = Client(w, "Alice", guild_rank=3), Client(w, "Bob", guild_rank=3)
    for x in (a, b):
        x.load_addon()
    w.tick(3)
    for x in (a, b):
        x.eval(HELPERS)
    return w, a, b


def game_of(x):
    return x.eval("local g = next(ns.Chess.Data().games) return g")


@case
def a_guild_game_plays_over_whispers_on_both_clients():
    w, a, b = pair()
    n0 = len(w.addon_log)
    gid = a.eval("local g = ns.Chess:Invite('Bob', 1) return g.id")
    w.tick(1)
    assert b.eval("return ns.Chess:Get(...).status", gid) == "invited"
    assert b.eval("return ns.Chess:Get(...).me", gid) == -1
    b.eval("ns.Chess:Accept(ns.Chess:Get(...))", gid)
    w.tick(1)
    assert a.eval("return ns.Chess:Get(...).status", gid) == "active"
    moves = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"]
    for i, mv in enumerate(moves):
        x = a if i % 2 == 0 else b
        assert x.eval("return (ns.Chess:Play(ns.Chess:Get(...), select(2, ...)))", gid, mv) is True, mv
        w.tick(1)
    fa = a.eval("return ns.ChessRules.ToFEN(ns.Chess:Position(ns.Chess:Get(...)))", gid)
    fb = b.eval("return ns.ChessRules.ToFEN(ns.Chess:Position(ns.Chess:Get(...)))", gid)
    assert fa == fb, (fa, fb)
    assert a.eval("return ns.Chess:Get(...).acked", gid) == 6
    # out of turn and illegal: refused
    assert b.eval("return (ns.Chess:Play(ns.Chess:Get(...), 'e8e7'))", gid) is False
    assert a.eval("return (ns.Chess:Play(ns.Chess:Get(...), 'e1e3'))", gid) is False
    # a forged move from the wire for the wrong side changes nothing
    b.eval("ns.Chess:Whisper('Alice', { t = 'CHM', id = ..., n = 7, m = 'd7d6' })", gid)
    w.tick(1)
    assert a.eval("return #ns.Chess:Get(...).moves", gid) == 6
    # the traffic: the whispers all on the game prefix
    msgs = [m for m in w.addon_log[n0:] if m.get("chat_type") == "WHISPER"]
    assert msgs and all(m["prefix"] == "CDLg" for m in msgs), {m["prefix"] for m in msgs}
    no_errors(w)


@case
def a_move_made_while_the_opponent_is_offline_reaches_them_on_login():
    w, a, b = pair()
    gid = a.eval("return ns.Chess:Invite('Bob', 1).id")
    w.tick(1)
    b.eval("ns.Chess:Accept(ns.Chess:Get(...))", gid)
    w.tick(1)
    b.logout()
    w.tick(2)
    assert a.eval("return (ns.Chess:Play(ns.Chess:Get(...), 'd2d4'))", gid) is True
    w.tick(2)
    assert a.eval("return ns.Chess:Get(...).acked", gid) == 0
    b.login()
    b.eval(HELPERS)
    w.tick(25)
    assert b.eval("return #ns.Chess:Get(...).moves", gid) == 1
    assert b.eval("return ns.Chess:MyTurn(ns.Chess:Get(...))", gid) is True
    no_errors(w)


@case
def resigning_and_draws_end_the_game_for_both_and_the_ladder_agrees():
    w = World()
    a, b, carol = (Client(w, n, guild_rank=3) for n in ("Alice", "Bob", "Carol"))
    for x in (a, b, carol):
        x.load_addon()
    w.tick(3)
    gid = a.eval("return ns.Chess:Invite('Bob', 1).id")
    w.tick(1)
    b.eval("ns.Chess:Accept(ns.Chess:Get(...))", gid)
    w.tick(1)
    for i, mv in enumerate(["e2e4", "e7e5"]):
        (a if i == 0 else b).eval("ns.Chess:Play(ns.Chess:Get(...), select(2, ...))", gid, mv)
        w.tick(1)
    b.eval("ns.Chess:Resign(ns.Chess:Get(...))", gid)
    w.tick(2)
    assert a.eval("local g = ns.Chess:Get(...) return g.status .. ' ' .. g.result .. ' ' .. g.reason", gid) == "over 1-0 resign"
    assert a.eval("return ns.Chess:MyResult(ns.Chess:Get(...))", gid) == "win"
    assert b.eval("return ns.Chess:MyResult(ns.Chess:Get(...))", gid) == "loss"
    # a second game, drawn by agreement
    g2 = b.eval("return ns.Chess:Invite('Alice', 1).id")
    w.tick(1)
    a.eval("ns.Chess:Accept(ns.Chess:Get(...))", g2)
    w.tick(1)
    for i, mv in enumerate(["d2d4", "d7d5"]):
        (b if i == 0 else a).eval("ns.Chess:Play(ns.Chess:Get(...), select(2, ...))", g2, mv)
        w.tick(1)
    a.eval("ns.Chess:OfferDraw(ns.Chess:Get(...))", g2)
    w.tick(1)
    assert b.eval("return ns.Chess:Get(...).drawFrom", g2) is not None
    b.eval("ns.Chess:AnswerDraw(ns.Chess:Get(...), true)", g2)
    w.tick(2)
    assert a.eval("return ns.Chess:Get(...).result", g2) == "1/2-1/2"
    # everyone has both results and the same ratings (Carol only heard them on the guild channel)
    rat = lambda x: x.eval_py("local o = {} for _, p in ipairs(ns.Chess:Ratings()) do "
                              "o[#o + 1] = p.key:match('^[^-]+') .. '=' .. p.rating end return o")
    ra, rb, rc = rat(a), rat(b), rat(carol)
    assert ra == rb == rc and len(ra) == 2, (ra, rb, rc)
    assert ra[0].startswith("Alice="), ra
    no_errors(w)


@case
def someone_offline_catches_up_on_the_ladder_at_login():
    w = World()
    a, b, carol = (Client(w, n, guild_rank=3) for n in ("Alice", "Bob", "Carol"))
    for x in (a, b, carol):
        x.load_addon()
    w.tick(3)
    carol.logout()
    gid = a.eval("return ns.Chess:Invite('Bob', 1).id")
    w.tick(1)
    b.eval("ns.Chess:Accept(ns.Chess:Get(...))", gid)
    w.tick(1)
    for i, mv in enumerate(["f2f3", "e7e5", "g2g4", "d8h4"]):
        (a if i % 2 == 0 else b).eval("ns.Chess:Play(ns.Chess:Get(...), select(2, ...))", gid, mv)
        w.tick(1)
    assert a.eval("return ns.Chess:Get(...).reason", gid) == "checkmate"
    assert b.eval("return ns.Chess:MyResult(ns.Chess:Get(...))", gid) == "win"
    carol.login()
    w.tick(30)
    assert carol.eval("return (ns.Chess:Digest())") == 1
    no_errors(w)


@case
def the_panel_lobby_a_click_then_a_square_and_medivh_answers():
    w, c = boot()
    c.eval("ns.MainFrame:Open('games') ns.GamesUI:Select('chess')")
    w.tick(1)
    st = c.eval_py("return ns.ChessUI:_State()")
    assert st.get("game") is None and st["tab"] == "games", st
    # play: a new game against Medivh opens, I play the Alliance
    c.eval("ns.Chess:Prefs().color = 1 ns.Chess:Prefs().strength = 'apprentice'")
    gid = c.eval("local g = ns.Chess:NewAIGame(1, 'apprentice', false) ns.ChessUI:OpenGame(g) return g.id")
    e2, e4 = c.eval("return ns.ChessRules.ParseSquare('e2'), ns.ChessRules.ParseSquare('e4')")
    c.eval("ns.ChessUI._OnSquare(...)", e2, "LeftButton")
    assert c.eval_py("return ns.ChessUI:_State()")["sel"] == e2
    c.eval("ns.ChessUI._OnSquare(...)", e4, "LeftButton")
    assert c.eval("return ns.Chess:Get(...).moves[1]", gid) == "e2e4"
    w.tick(6)
    assert c.eval("return #ns.Chess:Get(...).moves", gid) == 2, "Medivh did not answer"
    # a promotion asks which piece
    c.eval("local g = ns.Chess:NewAIGame(1, 'apprentice', false) T_CH.pg = g "
           "g.moves = { 'h2h4', 'g7g5', 'h4g5', 'g8f6', 'g5g6', 'f6e4', 'g6g7', 'e4f6' } ns.ChessUI:OpenGame(g)")
    g7, h8 = c.eval("return ns.ChessRules.ParseSquare('g7'), ns.ChessRules.ParseSquare('h8')")
    c.eval("ns.ChessUI._OnSquare(...)", g7, "LeftButton")
    c.eval("ns.ChessUI._OnSquare(...)", h8, "LeftButton")
    assert c.eval("return #T_CH.pg.moves") == 8          # not yet: the choice is open
    assert c.eval("return ns.ChessUI._Promo():IsShown()") is True
    c.eval("ns.ChessUI._Promo().buttons[2]:Click()")    # queen, rook, bishop, knight: a rook
    assert c.eval("return T_CH.pg.moves[9]") == "g7h8r"
    no_errors(w)


@case
def the_hall_in_3d_puts_every_square_on_the_floor_and_shows_a_capture():
    import harness  # noqa: E402
    old = harness.LOAD_ROOMS
    harness.LOAD_ROOMS = True
    try:
        w, c = boot()
        c.eval("ns.MainFrame:Open('games') ns.GamesUI:Select('chess')")
        w.tick(1)
        st = c.eval_py("return ns.ChessUI:_State()")
        assert st["has3d"] is True, st
        # every square's middle stands on the room's floor, all within 1 yd of one another (a flat board)
        zs = c.eval_py("local B = ns.ChessUI._Board3D() local o = {} for i = 1, 64 do o[i] = B.z[ns.ChessRules.SQ[i]] end return o")
        assert max(zs) - min(zs) < 1.0, (min(zs), max(zs))
        # the board fits the room (the generator's box)
        span = c.eval_py("local B3, R = ns.ChessBoard3D, ns.ChessRules local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9 "
                         "for i = 1, 64 do for _, p in ipairs(B3.Corners(R.SQ[i])) do "
                         "x0, y0, x1, y1 = math.min(x0, p[1]), math.min(y0, p[2]), math.max(x1, p[1]), math.max(y1, p[2]) end end "
                         "local fl = ns.Render3D.Floor(ns.Render3D.RoomForBoss('Karazhan:Chess')) return { x0, y0, x1, y1, fl.w, fl.h }")
        assert span[0] > 0 and span[1] > 0 and span[2] < span[4] and span[3] < span[5], span
        # a game: a capture walks, strikes, the victim falls; Medivh waits until it is over
        gid = c.eval("local g = ns.Chess:NewAIGame(1, 'apprentice', false) "
                     "g.moves = { 'e2e4', 'd7d5' } ns.ChessUI:OpenGame(g) return g.id")
        w.tick(1)
        assert c.eval("local B = ns.ChessUI._Board3D() local n = 0 for _ in pairs(B.actors) do n = n + 1 end return n") == 32
        c.eval("ns.Chess:Play(ns.Chess:Get(...), 'e4d5')", gid)
        assert c.eval("return ns.ChessUI._Board3D():Busy()") is True
        w.tick(1.5)
        assert c.eval("return #ns.Chess:Get(...).moves", gid) == 3, "Medivh moved while the capture was shown"
        w.tick(8)
        assert c.eval("return ns.ChessUI._Board3D():Busy()") is False
        assert c.eval("return #ns.Chess:Get(...).moves", gid) == 4
        n = c.eval("local B = ns.ChessUI._Board3D() local n = 0 for _ in pairs(B.actors) do n = n + 1 end return n")
        want = c.eval("local pos, n = ns.Chess:Position(ns.Chess:Get(...)), 0 for i = 1, 64 do "
                      "if pos.b[ns.ChessRules.SQ[i]] ~= 0 then n = n + 1 end end return n", gid)
        assert n == want and want <= 31, (n, want)      # (one model per piece left: the fallen are gone)
        no_errors(w)
    finally:
        harness.LOAD_ROOMS = old


@case
def a_pieces_box_in_the_vector_form_reads_like_six_numbers():
    # The client documents GetActiveBoundingBox as two vectors (min, max) and answers six numbers in practice: a
    # piece's occluder box (Games/Chess/Board3D.lua View:Occluders) is read from either.
    import harness  # noqa: E402
    old = harness.LOAD_ROOMS
    harness.LOAD_ROOMS = True
    try:
        w, c = boot()
        c.eval("ns.MainFrame:Open('games') ns.GamesUI:Select('chess')")
        w.tick(1)
        assert c.eval_py("return ns.ChessUI:_State()")["has3d"] is True
        bb = c.eval_py("""
            local B = ns.ChessUI._Board3D()
            local function vec(x, y, z) return { GetXYZ = function() return x, y, z end } end
            local function six() return -1, -2, 0, 0.5, 1.5, 3 end
            local function two() return vec(-1, -2, 0), vec(0.5, 1.5, 3) end
            local out = {}
            for i, fn in ipairs({ six, two }) do
                local a = { x = 1, y = 1, z = 0, scale = 1, loadedOnce = true, GetActiveBoundingBox = fn }
                B.Occluders({ occ = {}, actors = { a }, anims = {} })
                out[i] = a.bb and { a.bb.r, a.bb.z1 } or false
            end
            return out""")
        assert bb[0] == [2, 3] and bb[1] == bb[0], bb
        no_errors(w)
    finally:
        harness.LOAD_ROOMS = old


@case
def the_hub_has_a_chess_poster_with_what_waits_for_you():
    w, c = boot()
    c.eval("ns.MainFrame:Open('games')")
    w.tick(0.5)
    ids = c.eval_py("local o = {} for i, p in ipairs(ns.GamesUI.__posters) do o[i] = p.id end return o")
    assert "chess" in ids, ids
    c.eval("local g = ns.Chess:NewAIGame(1, 'magus', true)")
    stat = c.eval("for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'chess' then "
                  "ns.GamesUI:ShowFront('chess') return p.summary end end")
    w.tick(0.5)
    stat = c.eval("for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'chess' then return p.summary end end")
    assert stat and "your move" in stat, stat
    no_errors(w)


@case
def the_poster_is_a_still_3d_scene_with_no_holes_in_its_floor():
    w, c = boot()
    c.eval("ns.MainFrame:Open('games')")
    w.tick(0.5)
    c.eval("ns.GamesUI:ShowFront('chess')")
    w.tick(1.5)
    got = c.eval_py(r"""
      local p for _, q in ipairs(ns.GamesUI.__posters) do if q.id == 'chess' then p = q end end
      local cv = p.cover
      local v = cv.view
      local w, h = cv:GetWidth(), cv:GetHeight()
      local holes, shown = 0, 0
      for _, tl in ipairs(cv.tiles) do
        if tl.tex:IsShown() then shown = shown + 1 else
          for _, q in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
            local x, y = v:Project(tl.x0 + q[1] * 5.6, tl.y0 + q[2] * 5.6, 0)
            if x and x > 0 and x < w and y > 0 and y < h then holes = holes + 1 end
          end
        end
      end
      -- every piece's feet inside the poster
      local out = 0
      for _, e in ipairs(cv.actors) do
        local x, y = v:Project(e.p.f * 5.6, e.p.r * 5.6, 0)
        if not x or x < 0 or x > w or y < 0 or y > h then out = out + 1 end
      end
      return { three = v ~= nil, front = cv.frontOnly, dirty = cv.dirty, shown = shown, holes = holes,
               actors = #cv.actors, out = out }
    """)
    assert got["three"] and got["front"] and not got["dirty"], got
    assert got["holes"] == 0 and got["shown"] > 100 and got["actors"] == 7 and got["out"] == 0, got
    # nothing is worked out again while it stands
    c.eval("local p for _, q in ipairs(ns.GamesUI.__posters) do if q.id == 'chess' then p = q end end "
           "local stage, n = p.cover.Stage, 0 p.cover.Stage = function(...) n = n + 1 return stage(...) end "
           "T_CH.count = function() return n end")
    w.tick(2)
    assert c.eval("return T_CH.count()") == 0
    # it is set only while it can be seen (a hidden scene projects nothing: the floor was lost in game), and set
    # again when shown
    c.eval("local p for _, q in ipairs(ns.GamesUI.__posters) do if q.id == 'chess' then p = q end end "
           "T_CH.cover = p.cover p.cover:Hide() p.cover.dirty = true")
    w.tick(0.5)
    assert c.eval("return T_CH.count()") == 0 and c.eval("return T_CH.cover.dirty") is True
    c.eval("T_CH.cover:Show()")
    w.tick(0.5)
    assert c.eval("return T_CH.count()") >= 1 and not c.eval("return T_CH.cover.dirty")
    no_errors(w)


@case
def the_hall_is_not_drawn_while_the_panel_fades():
    import harness  # noqa: E402
    old = harness.LOAD_ROOMS
    harness.LOAD_ROOMS = True
    try:
        w, c = boot()
        c.eval("ns.MainFrame:Open('games') ns.GamesUI:Select('chess') ns.Chess:Prefs().flat = nil "
               "ns.ChessUI:ApplyBoardMode()")
        w.tick(1)
        c.eval("ns.ChessUI:OpenGame(ns.Chess:NewAIGame(1, 'magus', false))")
        w.tick(0.5)
        B = "ns.ChessUI._Board3D()"
        assert c.eval("return %s.view.scene:IsShown()" % B) is True
        # (the hub fades the stage on the way back: opaque room pieces and models ignore that alpha)
        c.eval("%s.frame:GetParent():SetAlpha(0.5)" % B)
        w.tick(0.2)
        assert c.eval("return %s.view.scene:IsShown()" % B) is False
        assert c.eval("return %s.faded" % B) is True
        c.eval("%s.frame:GetParent():SetAlpha(1)" % B)
        w.tick(0.2)
        assert c.eval("return %s.view.scene:IsShown()" % B) is True
        assert c.eval("return %s.faded" % B) is False
        no_errors(w)
    finally:
        harness.LOAD_ROOMS = old


if __name__ == "__main__":
    run_all()
