"""Games hub + Council Bingo on the real addon.

Covers: pure card logic (deterministic per seed + player, free centre, 12 lines), the hub registry and tab,
only the leader / an assistant can start, the host's detector marking squares from raid events (deaths, wipes,
kills, rolls, combat log) and syncing them to every raider, non-hosts never detecting on their own, a forged BG
from a plain raider ignored, the first bingo announced once, /reload resuming the game via BGQ, and that
Bingo never reacts to loot / council traffic.

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


def raid(names=("Lee", "Rita", "Sam", "Bob"), leader="Lee", assistants=()):
    w = World()
    c = {}
    for n in names:
        c[n] = Client(w, n, guild_rank=3)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.make_raid(list(c.values()), leader=c[leader], assistants=[c[a] for a in assistants])
    w.tick(5)
    return w, c


def hits(cl):
    return cl.eval_py("local g = ns.Bingo:GetGame(); if not g then return {} end; "
                      "local t = {}; for id in pairs(g.hits) do t[#t+1] = id end; table.sort(t); return t") or []


def cleu(cl, sub, src=GROUP_PLAYER, dst=GROUP_PLAYER, *params):
    args = [0, sub, False, "src", "Src", src, 0, "dst", "Dst", dst, 0] + list(params)
    cl._call("combat_log", *args)


def said(c, n0):
    return [strip_codes(l) for l in printed_since(c, n0)]


# -- pure card logic -------------------------------------------------------------------------------------------------

@case
def card_is_deterministic_per_seed_and_player():
    w, c = solo("Alice", tick=2)
    a1 = c.eval_py("return ns.BingoCard.Build('s1', 'Alice-X', ns.BingoSquares:Ids())")
    a2 = c.eval_py("return ns.BingoCard.Build('s1', 'Alice-X', ns.BingoSquares:Ids())")
    b = c.eval_py("return ns.BingoCard.Build('s1', 'Bob-X', ns.BingoSquares:Ids())")
    a3 = c.eval_py("return ns.BingoCard.Build('s2', 'Alice-X', ns.BingoSquares:Ids())")
    assert a1 == a2 and a1 != b and a1 != a3
    assert len(a1) == 25 and a1[12] == "FREE"
    assert len(set(a1)) == 25, "no square twice on one card"
    no_errors(w)


@case
def score_counts_lines_and_the_free_centre():
    w, c = solo("Alice", tick=2)
    lines, marked = c.eval("local card = ns.BingoCard.Build('s', 'A', ns.BingoSquares:Ids()); "
                           "local lines, marked = ns.BingoCard.Score(card, {}); return lines, marked")
    assert (lines, marked) == (0, 1)
    # mark the middle row (cells 11-15): one line
    lines, marked = c.eval("local card = ns.BingoCard.Build('s', 'A', ns.BingoSquares:Ids()); local h = {}; "
                           "for i = 11, 15 do h[card[i]] = 1 end; local l, m = ns.BingoCard.Score(card, h); return l, m")
    assert (lines, marked) == (1, 5)
    # full card: 12 lines
    lines, marked = c.eval("local card = ns.BingoCard.Build('s', 'A', ns.BingoSquares:Ids()); local h = {}; "
                           "for i = 1, 25 do h[card[i]] = 1 end; local l, m = ns.BingoCard.Score(card, h); return l, m")
    assert (lines, marked) == (12, 25)
    assert c.eval("return #ns.BingoSquares.list >= 24")
    no_errors(w)


# -- hub ---------------------------------------------------------------------------------------------------------------

@case
def hub_lists_bingo_and_play_opens_the_tab():
    w, c = solo("Alice", tick=2)
    assert c.eval("return ns.Games:Get('bingo') ~= nil")
    c.slash("/cdl play bingo")
    w.tick(0.2)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "games"
    assert c.eval("return ns.Games:SubmitScore('bingo', 7)") is True
    assert c.eval("return ns.Games:SubmitScore('bingo', 3)") is False
    assert c.eval("return ns.Games:GetData('bingo').best") == 7
    no_errors(w)


@case
def solo_practice_game_marks_own_squares():
    w, c = solo("Alice", tick=2)
    c.slash("/cdl bingo start")
    w.tick(0.5)
    assert c.eval("return ns.Bingo:IsActive() and ns.Bingo:IsHost()")
    w.player_roll("Alice", value=100)
    w.tick(1)
    assert "roll_100" in hits(c)
    no_errors(w)


# -- raid play -----------------------------------------------------------------------------------------------------

@case
def only_leader_or_assistant_can_start():
    w, c = raid(assistants=("Rita",))
    n0 = len(c["Sam"].printed)
    c["Sam"].slash("/cdl bingo start")
    w.tick(2)
    assert not c["Sam"].eval("return ns.Bingo:IsActive()")
    assert any("only the raid leader" in l for l in said(c["Sam"], n0))
    c["Rita"].slash("/cdl bingo start")
    w.tick(2)
    for n in ("Lee", "Rita", "Sam", "Bob"):
        assert c[n].eval("return ns.Bingo:IsActive()"), n
        assert c[n].eval("return ns.Bingo:GetGame().host") == K("Rita"), n
    no_errors(w)


@case
def host_detects_and_everyone_sees_the_hits():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
    w.tick(2)
    # trash death (host only sees it: detection runs on the host alone)
    cleu(c["Lee"], "UNIT_DIED")
    cleu(c["Lee"], "UNIT_DIED", 0, GROUP_PET)
    cleu(c["Lee"], "ENVIRONMENTAL_DAMAGE", 0, GROUP_PLAYER, "Falling", 500)
    cleu(c["Lee"], "SPELL_CAST_SUCCESS", GROUP_PLAYER, 0, 32182, "Heroism", 1)
    cleu(c["Lee"], "SPELL_DAMAGE", GROUP_PLAYER, 0, 133, "Fireball", 4, 9000, 0, 4, 0, 0, 0, True)
    w.player_roll("Sam", value=69)
    w.tick(2)
    expected = {"death_trash", "pet_death", "fall", "lust", "big_crit", "roll_69"}
    for n in ("Lee", "Rita", "Sam", "Bob"):
        assert expected <= set(hits(c[n])), (n, hits(c[n]))
    no_errors(w)


@case
def encounters_wipes_and_kills():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
    w.tick(2)
    w.encounter(652, "Attumen", success=False)
    w.tick(1)
    assert "wipe" in hits(c["Sam"]) and "wipe_twice" not in hits(c["Sam"])
    w.encounter(652, "Attumen", success=False)
    w.tick(1)
    assert "wipe_twice" in hits(c["Sam"])
    w.encounter(652, "Attumen", success=True)
    w.tick(1)
    h = set(hits(c["Rita"]))
    assert {"boss_kill", "flawless", "speed_kill"} <= h, h
    no_errors(w)


@case
def non_host_never_detects_on_its_own():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
    w.tick(2)
    cleu(c["Sam"], "UNIT_DIED")
    c["Sam"].fire("CHAT_MSG_SYSTEM", "Sam rolls 1 (1-100)")
    w.tick(2)
    assert hits(c["Lee"]) == [] and hits(c["Sam"]) == []
    no_errors(w)


@case
def forged_state_from_a_plain_raider_is_ignored():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
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
    c["Lee"].slash("/cdl bingo start")
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
    c["Lee"].slash("/cdl bingo start")
    w.tick(2)
    c["Sam"].slash("/cdl bingo stop")
    w.tick(1)
    assert c["Lee"].eval("return ns.Bingo:IsActive()"), "only the host can stop"
    c["Lee"].slash("/cdl bingo stop")
    w.tick(2)
    for n in ("Lee", "Sam"):
        assert not c[n].eval("return ns.Bingo:IsActive()"), n
    no_errors(w)


@case
def reload_resumes_the_game():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
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
def bingo_ignores_loot_and_council_messages():
    w, c = raid()
    c["Lee"].slash("/cdl bingo start")
    w.tick(2)
    for msg in ("DROP", "LEDGER_UPDATED", "ROLL_UPDATED", "ROLL_STARTED"):
        c["Lee"].eval("ns:Fire(...)", msg)
    w.tick(2)
    assert hits(c["Lee"]) == []
    no_errors(w)


if __name__ == "__main__":
    run_all("games / Council Bingo")
