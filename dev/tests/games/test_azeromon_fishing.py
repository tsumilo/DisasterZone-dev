"""Azeromon: Fishing (Fishing.lua, 0.28).

Covers: Lee Brown teaches Fishing on top of two trades (secondary) and Journeyman at 75; Old Man Heming teaches
Expert; Brog sells the pole; facing water hints and casts; the bite comes, Space in the window hooks it, too soon
or too late loses it, a direction reels in; catches follow the water's table and skill gates; a hooked water
beast starts a wild battle; schools bite faster; low skill loses most catches; fish feed beasts (water beasts
twice); the Shiny Bauble lure; the bobber draws without errors.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fishing.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

CLOCK = 1790000000
POND = (28, 14)             # Goldshire: grass at (28, 14), the pond at (29, 14) to the right


def game(skill=1, pole=True, x=POND[0], y=POND[1], face="right", hour=12):
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.Azero.clockHour = %r" % hour)
    c.eval("ns.AzeroFish.clock = %d ns.AzeroCraft.clock = %d" % (CLOCK, CLOCK))
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('murkling', 30, ns.Azero.rng), 'caught')")
    if skill:
        c.eval("ns.Azero.save.prof = { fishing = %d }" % skill)
    if pole:
        c.eval("ns.Azero.save.bag.fishingpole = 1")
    c.eval("ns.Azero:EnterMap('town', %d, %d, '%s', true)" % (x, y, face))
    # keep the school of fish away from the spot (it would halve the bite times)
    c.eval("""local F, G = ns.AzeroFish, ns.Azero
      local d = G.DIRS[G.save.face]
      for i = 1, 50 do
        if not F.NearSchool(G.map, G.save.x + d[1], G.save.y + d[2]) then break end
        F.clock = F.clock + F.SCHOOL_MINUTES * 60
      end""")
    return w, c


def pending(c):
    return c.eval_py("local p = ns.Azero.pending return p and { kind = p.kind, text = p.text, biting = p.biting == true,"
                     " bite = p.bite, t = p.t }")


def until_bite(c, limit=200):
    for _ in range(limit):
        p = pending(c)
        if not p or p["kind"] != "fish" or p["biting"]:
            return p
        c.eval("ns.Azero:Update(0.1)")
    return pending(c)


def texts(c):
    out = []
    for _ in range(20):
        p = pending(c)
        if not p or p["kind"] != "text":
            break
        out.append(p["text"])
        c.eval("ns.Azero:Advance()")
    return out


def rig(c, rolls):
    """F.rng returns the given values in turn (then 1s)."""
    c.eval("local q = { %s } local i = 0 ns.AzeroFish.rng = function(a, b) i = i + 1 local v = q[i] or a"
           " return math.max(a, math.min(b, v)) end" % ", ".join(str(v) for v in rolls))


@case
def lee_brown_teaches_fishing_on_top_of_two_trades():
    w, c = game(skill=0, pole=False, x=34, y=15, face="up")
    c.eval("ns.Azero.save.prof = { mining = 10, herbalism = 5 } ns.Azero.save.money = 1000")
    lee = c.eval_py("for _, n in ipairs(ns.Azero.npcs) do if n.id == 'leebrown' then return { n.x, n.y, n.act or false } end end")
    assert lee == [34, 14, "fish"], lee
    c.eval("ns.Azero:PressA()")
    log = texts(c)
    assert any("Lee Brown" in t for t in log), log
    p = pending(c)
    assert p["kind"] == "choice" and "Learn Fishing" in p["text"], p
    c.eval("ns.Azero:Advance(1)")
    log = texts(c)
    assert any("You have learned Fishing" in t for t in log), log
    r = c.eval_py("return { ns.AzeroCraft.Skill('fishing'), #ns.AzeroCraft.Known(), ns.Azero.save.money }")
    assert r == [1, 2, 950], r
    no_errors(w)


@case
def journeyman_at_75_from_lee_and_expert_from_heming():
    w, c = game(skill=74, x=34, y=15, face="up")
    c.eval("ns.Azero.save.money = 5000")
    c.eval("ns.Azero:PressA()")
    log = texts(c)
    assert any("Fishing 75" in t for t in log), log
    c.eval("ns.Azero.save.prof.fishing = 80 ns.Azero:PressA()")
    texts(c)
    c.eval("ns.Azero:Advance(1)")
    log = texts(c)
    assert any("Journeyman in Fishing" in t for t in log), log
    assert c.eval("return ns.AzeroCraft.Cap('fishing')") == 150
    c.eval("ns.Azero.save.prof.fishing = 130 ns.Azero:EnterMap('bootybay', 10, 17, 'down', true) ns.Azero:PressA()")
    texts(c)
    c.eval("ns.Azero:Advance(1)")
    log = texts(c)
    assert any("Expert in Fishing" in t for t in log), log
    assert c.eval("return ns.AzeroCraft.Cap('fishing')") == 175
    no_errors(w)


@case
def brog_sells_the_pole():
    w, c = game()
    stock = c.eval_py("return ns.AzeroData.ShopStock(nil)")
    assert "fishingpole" in stock, stock
    no_errors(w)


@case
def facing_water_hints_and_needs_skill_and_pole():
    w, c = game(skill=0, pole=False)
    assert c.eval("local t = ns.Azero:InteractHint() return t") == "Fish  (needs Fishing)"
    c.eval("ns.Azero:PressA()")
    assert any("Lee Brown" in t for t in texts(c))
    c.eval("ns.Azero.save.prof = { fishing = 1 }")
    assert c.eval("return (ns.Azero:InteractHint())") == "Fish  (needs a Fishing Pole)"
    c.eval("ns.Azero:PressA()")
    assert any("Fishing Pole" in t for t in texts(c))
    c.eval("ns.Azero.save.bag.fishingpole = 1")
    assert c.eval("return (ns.Azero:InteractHint())") == "Fish"
    no_errors(w)


@case
def hook_in_the_window_catches_a_fish():
    w, c = game()
    rig(c, [40, 1, 1, 1])                     # wait 4.0 s; no escape; smallfish (first entry); skill-up
    c.eval("ns.Azero:PressA()")
    p = pending(c)
    assert p["kind"] == "fish" and abs(p["bite"] - 4.0) < 1e-6, p
    p = until_bite(c)
    assert p["biting"] and 3.9 <= p["t"] <= 4.2, p
    c.eval("ns.AzeroFish:Key(ns.Azero, ns.Azero.pending, 'A')")
    log = texts(c)
    assert any("You caught a Raw Brilliant Smallfish" in t for t in log), log
    assert any("increased to 2" in t for t in log), log
    r = c.eval_py("return { ns.Azero.save.bag.smallfish, ns.Azero.save.prof.fishing }")
    assert r == [1, 2], r
    no_errors(w)


@case
def too_soon_too_late_and_walking_off():
    w, c = game()
    rig(c, [50])
    c.eval("ns.Azero:PressA() ns.Azero:Update(0.5) ns.AzeroFish:Key(ns.Azero, ns.Azero.pending, 'A')")
    assert any("too soon" in t for t in texts(c))
    rig(c, [50])
    c.eval("ns.Azero:PressA()")
    until_bite(c)
    for _ in range(15):
        c.eval("ns.Azero:Update(0.1)")
    assert any("got away" in t for t in texts(c))
    rig(c, [50])
    c.eval("ns.Azero:PressA() ns.Azero:Update(0.5) ns.Azero:SetDir('left')")
    assert pending(c) is None
    c.eval("ns.Azero:SetDir(nil)")
    assert c.eval("return ns.Azero.save.bag.smallfish") is None
    no_errors(w)


@case
def catches_follow_the_table_and_skill_gates():
    w, c = game(skill=40)
    # Westfall's table without catfish (skill 50): weights 30 + 18 + 8 + 8 + 4 + 10 = 78
    r = c.eval_py("""local F, D = ns.AzeroFish, ns.AzeroData
      local seen = {}
      for v = 1, 78 do
        F.rng = function() return v end
        local e = F.Roll(D.fishWaters.westfall, 40, false)
        seen[e.item or e.beast] = (seen[e.item or e.beast] or 0) + 1
      end
      return seen""")
    assert r == {"mudsnapper": 30, "blackmouth": 18, "sicklyfish": 8, "boot": 8, "bauble": 4, "coastrunner": 10}, r
    hi = c.eval_py("""local F, D = ns.AzeroFish, ns.AzeroData
      F.rng = function() return 31 end
      return F.Roll(D.fishWaters.westfall, 60, false).item""")
    assert hi == "catfish", hi
    no_errors(w)


@case
def a_hooked_murkling_starts_a_wild_battle():
    w, c = game()
    rig(c, [40, 1, 100])                      # wait; no escape; last entry = the Murkling
    c.eval("ns.Azero:PressA()")
    until_bite(c)
    c.eval("ns.AzeroFish:Key(ns.Azero, ns.Azero.pending, 'A')")
    log = texts(c)
    assert any("It's a wild Murkling" in t for t in log), log
    p = pending(c)
    assert p and p["kind"] == "battle", p
    sp = c.eval("return ns.Azero.pending.battle.foes[1].sp")
    assert sp == "murkling", sp
    no_errors(w)


@case
def schools_bite_twice_as_fast():
    w, c = game()
    sc = c.eval_py("local s = ns.AzeroFish.School(ns.Azero.map) return { s.x, s.y }")
    shore = c.eval_py("local out = {} for _, t in ipairs(ns.AzeroFish.Shore(ns.Azero.map)) do out[#out + 1] = { t.x, t.y } end return out")
    assert sc in shore, (sc, shore)
    c.eval("ns.AzeroFish.clock = %d" % (CLOCK + 20 * 60))
    sc2 = c.eval_py("local s = ns.AzeroFish.School(ns.Azero.map) return { s.x, s.y }")
    c.eval("ns.AzeroFish.clock = %d" % CLOCK)
    # stand on land next to the school and cast at it
    spot = c.eval_py("""local m, s = ns.Azero.map, ns.AzeroFish.School(ns.Azero.map)
      for dir, d in pairs(ns.Azero.DIRS) do
        local x, y = s.x - d[1], s.y - d[2]
        local k = m.key(x, y)
        if not m.water[k] and not m.solid[k] then return { x, y, dir } end
      end""")
    c.eval("ns.Azero:EnterMap('town', %d, %d, '%s', true)" % (spot[0], spot[1], spot[2]))
    rig(c, [40])
    c.eval("ns.Azero:PressA()")
    p = pending(c)
    assert p["kind"] == "fish" and abs(p["bite"] - 2.0) < 1e-6, (p, sc, sc2)
    no_errors(w)


@case
def low_skill_loses_most_catches():
    w, c = game(skill=1)
    r = c.eval_py("""local F, D = ns.AzeroFish, ns.AzeroData
      return { F.EscapeChance(1, D.fishWaters.elwynn), F.EscapeChance(60, D.fishWaters.jungle),
               F.SkillUpChance(10, D.fishWaters.elwynn), F.SkillUpChance(90, D.fishWaters.elwynn) }""")
    assert r == [0, 90, 100, 10], r
    no_errors(w)


@case
def fish_feed_beasts_and_water_beasts_twice():
    w, c = game()
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('emberwhelp', 12, ns.Azero.rng), 'caught')")
    c.eval("ns.Azero.save.bag.mudsnapper = 2 for _, m in ipairs(ns.Azero.save.party) do m.hp = 1 end")
    a = c.eval("return ns.Azero:UseItemOutside('mudsnapper', 1)")
    b = c.eval("return ns.Azero:UseItemOutside('mudsnapper', 2)")
    assert "gobbles up" in a and "by 36" in a, a
    assert "eats" in b and "by 18" in b, b
    no_errors(w)


@case
def the_bauble_lure_speeds_bites():
    w, c = game()
    c.eval("ns.Azero.save.bag.bauble = 1")
    msg = c.eval("return ns.AzeroFish:UseLure('bauble')")
    assert "10 minutes" in msg, msg
    assert c.eval("return ns.AzeroFish.LureOn()") is True
    rig(c, [50])
    c.eval("ns.Azero:PressA()")
    assert abs(pending(c)["bite"] - 3.0) < 1e-6
    c.eval("ns.AzeroFish.clock = %d" % (CLOCK + 601))
    assert c.eval("return ns.AzeroFish.LureOn()") is False
    no_errors(w)


@case
def the_bobber_draws_in_the_ui():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero.save.prof = { fishing = 1 } ns.Azero.save.bag.fishingpole = 1")
    c.eval("ns.Azero:EnterMap('town', %d, %d, 'right', true)" % POND)
    w.tick(0.2)
    c.eval("ns.AzeroFish.rng = function(a) return a end ns.AzeroUI._HandleKey('A')")
    w.tick(0.5)
    assert pending(c)["kind"] == "fish"
    assert c.eval("return ns.AzeroUI._KeyContext and ns.AzeroUI._KeyContext() or 'fish'") == "fish"
    for _ in range(40):
        w.tick(0.1)
        if pending(c)["biting"]:
            break
    assert pending(c)["biting"]
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    p = pending(c)
    assert p["kind"] == "text" and "You caught" in p["text"], p
    no_errors(w)


if __name__ == "__main__":
    run_all(globals())
