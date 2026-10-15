"""Azeromon: the aftermath (Aftermath.lua, 0.32): places heal over real days after a win.

Covers: a win records when it happened and older wins start their week on load; Westfall's north field goes
fenced (day 1), ploughed (3), shoots (5), wheat (7), its fence solid and the herb and ore under it no longer
gatherable; the Defias leave, the militia stands by its standards days 1 to 6, farmhands and Mara work the field
from day 3 while Sentinel Hill's Mara is gone (who's-where too); the feast (bonfire, dancers) only on the evening
of day 7; Furlbrow's lines follow the week; Darkshire's lamps are dark until Stitches falls, its mist thins over
three nights, the bell tolls once at dusk, villagers and a second watchman come out after; it draws in the UI.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_aftermath.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

T0 = 1790000000
DAY = 86400


def game(flag=None, day=0, hour=12):
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.Azero.clockHour = %r ns.AzeroAftermath.clock = %d" % (hour, T0))
    if flag:
        c.eval("ns.Azero:SetFlag(%r) ns.AzeroAftermath.clock = %d" % (flag, T0 + day * DAY + 60))
    return w, c


def enter(c, mid, x, y, face="down"):
    c.eval("ns.Azero:EnterMap(%r, %d, %d, %r, true)" % (mid, x, y, face))


def field(c):
    return c.eval_py("""local m = ns.Azero.map local cv = ns.AzeroAftermath.Covers(m) or {}
      return { fence = cv[m.key(5, 2)] or false, mid = cv[m.key(6, 5)] or false, corner = cv[m.key(3, 3)] or false,
               solid = m.solid[m.key(5, 2)] == true, ore = ns.AzeroCraft:NodeState('westfall', m.node[m.key(9, 5)]) == true,
               herb = ns.AzeroCraft:NodeState('westfall', m.node[m.key(8, 2)]) == true }""")


def people(c):
    return c.eval_py("""local out = {}
      for _, n in ipairs(ns.Azero.npcs) do out[n.id] = { x = n.x, y = n.y, hidden = n.hidden == true } end return out""")


def say(c, npc_id):
    c.eval("""for _, n in ipairs(ns.Azero.npcs) do if n.id == %r then ns.Azero:Run(n.def.script, n) end end""" % npc_id)
    out = []
    for _ in range(4):
        p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
        if not p or p[0] != "text":
            break
        out.append(p[1])
        c.eval("ns.Azero:Advance()")
    return " ".join(out)


@case
def a_win_records_when_and_old_wins_start_their_week_on_load():
    w, c = game("badge_vancleef", day=3)
    assert c.eval("return ns.Azero:AfterDay('badge_vancleef')") == 3
    assert c.eval("return ns.Azero:AfterDay('badge_nightwatch')") is None
    # a save that won before the aftermath existed: no time recorded, the week starts now
    c.eval("ns.Azero.save.flags.badge_nightwatch = true ns.Azero.save.flagAt.badge_nightwatch = nil ns.AzeroAftermath.Migrate()")
    assert c.eval("return ns.Azero:AfterDay('badge_nightwatch')") == 0
    no_errors(w)


@case
def westfalls_field_goes_from_fence_to_wheat():
    w, c = game()
    enter(c, "westfall", 12, 10)
    f = field(c)
    assert f == {"fence": False, "mid": False, "corner": False, "solid": False, "ore": True, "herb": True}, f
    expect = {1: ("fence", False, True), 3: ("fence", "field_soil", True), 5: ("fence", None, True),
              7: ("fence", "wtall_c", True)}
    for day, (fence, mid, solid) in expect.items():
        c.eval("ns.Azero:SetFlag('badge_vancleef') ns.Azero.save.flagAt.badge_vancleef = %d ns.AzeroAftermath.clock = %d" % (T0, T0 + day * DAY + 60))
        enter(c, "westfall", 12, 10)
        f = field(c)
        assert f["fence"] == fence and f["solid"] == solid, (day, f)
        if mid:
            assert f["mid"] == mid, (day, f)
        assert f["herb"] is False, (day, f)                      # under the fence from day 1
        assert f["ore"] is (day < 3), (day, f)                   # ploughed over from day 3
    assert field(c)["corner"] == "wtall_tl"
    c.eval("ns.AzeroAftermath.clock = %d" % (T0 + 5 * DAY + 60))
    assert field(c)["mid"] in ("field_crop_a", "field_crop_b")
    # a new game (no win): the fence is gone again and the vein is back
    c.eval("ns.Azero:NewGame() ns.Azero.started = true")
    enter(c, "westfall", 12, 10)
    f = field(c)
    assert f["fence"] is False and f["solid"] is False and f["ore"] is True, f
    no_errors(w)


@case
def westfalls_people_follow_the_week():
    w, c = game()
    enter(c, "westfall", 12, 10)
    p = people(c)
    assert not p["defias3"]["hidden"] and p["wfmilitia1"]["hidden"] and p["farmhand1"]["hidden"], p
    for day in (1, 3, 8):
        c.eval("ns.Azero:SetFlag('badge_vancleef') ns.Azero.save.flagAt.badge_vancleef = %d ns.AzeroAftermath.clock = %d" % (T0, T0 + day * DAY + 60))
        enter(c, "westfall", 12, 10)
        p = people(c)
        assert p["defias1"]["hidden"] and p["defias3"]["hidden"], (day, p)
        assert p["wfmilitia1"]["hidden"] is (day > 6), (day, p["wfmilitia1"])
        assert p["farmhand1"]["hidden"] is (day < 3), (day, p["farmhand1"])
        if day >= 3:
            assert (p["farmhand1"]["x"], p["farmhand1"]["y"]) == (6, 4) and (p["wfmara"]["x"], p["wfmara"]["y"]) == (4, 6), p
        assert p["dancer1"]["hidden"], (day, p)
    # Sentinel Hill's Mara has gone home, and the who's-where page knows
    enter(c, "sentinel", 10, 11)
    assert people(c)["refugee"]["hidden"]
    names = c.eval_py("local o = {} for _, e in ipairs(ns.AzeroRoutine.Town('sentinel')) do o[#o + 1] = e.name end return o")
    assert "Mara" not in names, names
    wf = c.eval_py("local o = {} for _, e in ipairs(ns.AzeroRoutine.Town('westfall')) do o[#o + 1] = e.name .. ':' .. e.label end return o")
    assert "Mara:Working her field" in wf, wf
    no_errors(w)


@case
def the_feast_is_the_evening_of_day_seven_only():
    w, c = game("badge_vancleef", day=7, hour=12)
    enter(c, "westfall", 12, 12)
    assert people(c)["dancer1"]["hidden"]
    assert c.eval_py("local o = {} for _, p in ipairs(ns.AzeroAftermath.Props(ns.Azero.map)) do o[#o + 1] = p.kind end return o") == ["standard", "standard"]
    c.eval("ns.Azero.clockHour = 20")
    enter(c, "westfall", 12, 12)
    p = people(c)
    assert not p["dancer1"]["hidden"] and not p["dancer4"]["hidden"], p
    kinds = c.eval_py("local o = {} for _, p in ipairs(ns.AzeroAftermath.Props(ns.Azero.map)) do o[#o + 1] = p.kind end return o")
    assert kinds == ["standard", "standard", "bonfire"], kinds
    assert "guest of honour" not in say(c, "furlbrow") and "To the harvest" in say(c, "furlbrow")
    c.eval("ns.AzeroAftermath.clock = %d" % (T0 + 8 * DAY + 60))
    enter(c, "westfall", 12, 12)
    assert people(c)["dancer1"]["hidden"]
    no_errors(w)


@case
def furlbrows_lines_follow_the_week():
    w, c = game()
    enter(c, "westfall", 14, 6, "up")
    assert "took Old Blanchy" in say(c, "furlbrow")
    lines = {0: "can hardly believe it", 1: "planted its standards", 3: "Mara's come home", 5: "come up", 7: "guest of honour",
             9: "Westfall owes you"}
    for day, bit in lines.items():
        c.eval("ns.Azero:SetFlag('badge_vancleef') ns.Azero.save.flagAt.badge_vancleef = %d ns.AzeroAftermath.clock = %d" % (T0, T0 + day * DAY + 60))
        assert bit in say(c, "furlbrow"), (day, bit)
    no_errors(w)


@case
def darkshire_is_dark_until_stitches_falls():
    w, c = game(hour=23)
    enter(c, "darkshire", 12, 14)
    r = c.eval_py("""local R, A = ns.AzeroRoutine, ns.AzeroAftermath
      return { R.LampLit('darkshire', 1), R.LampLit('darkshire', 7), A.Mist('darkshire'), R.LampLit('town', 1) }""")
    assert r[0] is False and r[1] is False and r[2] == 1.5, r
    p = people(c)
    assert p["dsvillager1"]["hidden"] and p["dswatch2"]["hidden"], p
    mists = []
    for day in (0, 1, 2, 3, 10):
        c.eval("ns.Azero:SetFlag('badge_nightwatch') ns.Azero.save.flagAt.badge_nightwatch = %d ns.AzeroAftermath.clock = %d" % (T0, T0 + day * DAY + 60))
        mists.append(c.eval_py("return ns.AzeroAftermath.Mist('darkshire')"))
    assert mists == [1.2, 1.0, 0.8, 0.55, 0.55], mists
    assert c.eval_py("return ns.AzeroRoutine.LampLit('darkshire', 3)") is True
    c.eval("ns.Azero.clockHour = 20")
    enter(c, "darkshire", 12, 14)
    p = people(c)
    assert not p["dsvillager1"]["hidden"] and (p["dsvillager1"]["x"], p["dsvillager1"]["y"]) == (15, 13), p
    assert not p["dswatch2"]["hidden"], p
    no_errors(w)


@case
def the_bell_tolls_once_at_dusk():
    w, c = game("badge_nightwatch", day=2, hour=18)
    enter(c, "darkshire", 12, 14)
    n0 = len(c.eval_py("return __MOCK.sounds") or [])
    for _ in range(3):
        c.eval("ns.AzeroAftermath:Update()")
    sounds = (c.eval_py("return __MOCK.sounds") or [])[n0:]
    assert sounds.count(566564) == 1, sounds
    c.eval("ns.Azero.clockHour = 21 ns.AzeroAftermath._Reset()")
    n0 = len(c.eval_py("return __MOCK.sounds") or [])
    c.eval("ns.AzeroAftermath:Update()")
    assert 566564 not in (c.eval_py("return __MOCK.sounds") or [])[n0:]
    no_errors(w)


@case
def the_feast_draws_in_the_ui():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle() ns.Azero.clockHour = 21 ns.AzeroAftermath.clock = %d" % T0)
    c.eval("ns.Azero:SetFlag('badge_vancleef') ns.AzeroAftermath.clock = %d" % (T0 + 7 * DAY + 60))
    c.eval("ns.Azero:EnterMap('westfall', 12, 11, 'up', true)")
    for _ in range(6):
        w.tick(0.1)
    tiles = c.eval_py("return ns.AzeroUI._PropTiles()") or []
    assert "bonfire_0_0" in tiles and any(t.startswith("flame_") for t in tiles) and "standard_0_1" in tiles, tiles
    no_errors(w)


if __name__ == "__main__":
    run_all()
