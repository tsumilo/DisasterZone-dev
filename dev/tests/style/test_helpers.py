"""Refactor 1.4, phase 1C: the shared data helpers that replace the local copies across the addon.

Util.Now / IsInt / DemoOn / Jitter / NewRng / ShortName(anyRealm) (Core/Util.lua), ns.SlotLabel / ns.ClassName /
the spec icons on ns.SPECS / ns.SpecIcon / ns.PROFESSIONS (Core/Constants.lua) and DB:GuildBucket (Core/DB.lua).
Each helper keeps the behaviour of the most common local copy, so callers can move to it without a change.

Run: luaenv\\Scripts\\python.exe tests\\style\\test_helpers.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

MOD = 2147483647


def adler32(s):
    a, b = 1, 0
    for ch in s.encode("utf-8"):
        a = (a + ch) % 65521
        b = (b + a) % 65521
    return b * 65536 + a


# ------------------------------------------------------------------------------------------------------------------
# Util
# ------------------------------------------------------------------------------------------------------------------
@case
def now_is_the_server_time():
    w, c = solo()
    got, want = c.eval("return ns.Util.Now(), (GetServerTime and GetServerTime()) or time()")
    assert got == want, (got, want)
    no_errors(w)


@case
def is_int_takes_optional_bounds_like_the_copies():
    w, c = solo()
    cases = [
        ("return ns.Util.IsInt(5, 0, 10)", True),
        ("return ns.Util.IsInt(0, 0, 10)", True),
        ("return ns.Util.IsInt(10, 0, 10)", True),
        ("return ns.Util.IsInt(11, 0, 10)", False),
        ("return ns.Util.IsInt(-1, 0, 10)", False),
        ("return ns.Util.IsInt(2.5, 0, 10)", False),
        ("return ns.Util.IsInt('5', 0, 10)", False),
        ("return ns.Util.IsInt(nil, 0, 10)", False),
        ("return ns.Util.IsInt(0/0, 0, 10)", False),
        ("return ns.Util.IsInt(math.huge, 0, 10)", False),
        ("return ns.Util.IsInt(7)", True),                 # no bounds (DungeonRuns' copy)
        ("return ns.Util.IsInt(-7)", True),
        ("return ns.Util.IsInt(7.25)", False),
        ("return ns.Util.IsInt(3, 5)", False),             # only a lower bound
        ("return ns.Util.IsInt(30, nil, 20)", False),      # only an upper bound
        ("return ns.Util.IsInt(-30, nil, 20)", True),
    ]
    for code, want in cases:
        got = c.eval(code)
        assert got is want, (code, got, want)
    no_errors(w)


@case
def demo_on_is_a_boolean_that_follows_demo_mode():
    w, c = solo()
    assert c.eval("return ns.Util.DemoOn()") is False
    c.eval("ns.Demo:SetEnabled(true)")
    w.tick(0.5)
    assert c.eval("return ns.Util.DemoOn()") is True
    c.eval("ns.Demo:SetEnabled(false)")
    w.tick(0.5)
    assert c.eval("return ns.Util.DemoOn()") is False
    # Before Demo exists (or without IsEnabled): false, not nil.
    assert c.eval("local D = ns.Demo; ns.Demo = nil; local v = ns.Util.DemoOn(); ns.Demo = D; return v") is False
    no_errors(w)


@case
def jitter_is_per_character_and_key_and_stays_in_range():
    w, c = solo("Alice")
    me = c.eval("return ns.Util.PlayerKey()")
    for key, spread in (("fb", 10), ("acc", 5), ("hello", 2.5), ("", 1)):
        got = c.eval("return ns.Util.Jitter(...)", key, spread)
        want = (adler32(me + key) % 1000) / 1000 * spread   # Core/Feedback.lua's copy
        assert abs(got - want) < 1e-9, (key, got, want)
        assert 0 <= got < spread, (key, got)
    # The same every time; another key gives another value; spread defaults to 1; a nil key is "".
    a1, a2 = c.eval("return ns.Util.Jitter('x', 10), ns.Util.Jitter('x', 10)")
    assert a1 == a2
    vals = c.eval_py("local t = {} for i = 1, 20 do t[i] = ns.Util.Jitter('k' .. i, 100) end return t")
    assert len(set(vals)) > 10, vals
    frac = c.eval("return ns.Util.Jitter('x')")
    assert 0 <= frac < 1 and abs(frac * 10 - a1) < 1e-9, (frac, a1)
    assert c.eval("return ns.Util.Jitter(nil, 4)") == c.eval("return ns.Util.Jitter('', 4)")
    # Draws nothing from math.random.
    seq1 = c.eval_py("math.randomseed(42) local t = {} for i = 1, 3 do t[i] = math.random(1000) end return t")
    seq2 = c.eval_py("math.randomseed(42) ns.Util.Jitter('a', 3) ns.Util.Jitter('b', 3) local t = {} "
                     "for i = 1, 3 do t[i] = math.random(1000) end return t")
    assert seq1 == seq2
    no_errors(w)


def park_miller(seed, n):
    state = (int(seed) % (MOD - 1)) + 1
    out = []
    for _ in range(n):
        state = (state * 16807) % MOD
        out.append(state)
    return out


@case
def new_rng_matches_demo_generator_and_is_independent():
    w, c = solo()
    for seed in (1, 7, 20070116 + 4242, 123456789, MOD + 5, 0):
        got = c.eval_py("local r = ns.Util.NewRng(...) local t = {} for i = 1, 8 do t[i] = r.Next() end return t",
                        seed)
        want = [s / MOD for s in park_miller(seed, 8)]
        assert all(abs(g - x) < 1e-12 for g, x in zip(got, want)), (seed, got, want)
        assert all(0 < g < 1 for g in got)
    # Int / Range ride on the same stream.
    ints = c.eval_py("local r = ns.Util.NewRng(99) local t = {} for i = 1, 50 do t[i] = r.Int(6) end return t")
    want = [1 + int(s / MOD * 6) for s in park_miller(99, 50)]
    assert ints == want, (ints, want)
    rng = c.eval_py("local r = ns.Util.NewRng(5) local t = {} for i = 1, 200 do t[i] = r.Range(3, 9) end return t")
    assert min(rng) >= 3 and max(rng) <= 9 and len(set(rng)) == 7, rng
    # Two generators with the same seed are independent of each other and of math.random; bad seeds act as 1.
    same = c.eval("local a, b = ns.Util.NewRng(11), ns.Util.NewRng(11) local a1 = a.Next() a.Next() "
                  "math.random() local b1 = b.Next() return a1 == b1 and b.Next() ~= b1")
    assert same is True
    for bad in ("nil", "'abc'", "0/0", "math.huge"):
        got = c.eval("return ns.Util.NewRng(%s).Next()" % bad)
        assert abs(got - park_miller(1, 1)[0] / MOD) < 1e-12, (bad, got)
    no_errors(w)


@case
def short_name_any_realm_strips_every_realm():
    w, c = solo("Alice")
    me = c.eval("return ns.Util.PlayerKey()")
    assert c.eval("return ns.Util.ShortName(...)", me) == "Alice"
    assert c.eval("return ns.Util.ShortName('Bob-Other')") == "Bob-Other"         # unchanged without anyRealm
    assert c.eval("return ns.Util.ShortName('Bob-Other', true)") == "Bob"
    assert c.eval("return ns.Util.ShortName(..., true)", me) == "Alice"
    assert c.eval("return ns.Util.ShortName('Bob', true)") == "Bob"
    assert c.eval("return ns.Util.ShortName(nil, true)") == ""
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------------------------------------------
@case
def slot_label_uses_the_slot_table_and_one_fallback():
    w, c = solo()
    labels = c.eval_py("local t = {} for sid = 1, ns.NUM_SLOTS do t[sid] = ns.SlotLabel(sid) end return t")
    want = c.eval_py("local t = {} for sid = 1, ns.NUM_SLOTS do t[sid] = ns.SLOTS[sid].label end return t")
    assert labels == want and labels[0] == "Head" and labels[16] == "Ranged / Relic", labels
    assert c.eval("return ns.SlotLabel('5')") == "Chest"
    assert c.eval("return ns.SlotLabel(99)") == "Slot 99"
    assert c.eval("return ns.SlotLabel(0)") == "Slot 0"
    assert c.eval("return ns.SlotLabel(nil)") == "Slot nil"
    no_errors(w)


@case
def class_name_english_localized_and_unknown():
    w, c = solo()
    assert c.eval("return ns.ClassName('PALADIN')") == "Paladin"
    assert c.eval("return ns.ClassName('PALADIN', true)") == "Paladin"
    # Localized follows the client's table; English ignores it.
    got = c.eval("local old = LOCALIZED_CLASS_NAMES_MALE.PALADIN LOCALIZED_CLASS_NAMES_MALE.PALADIN = 'Paladín' "
                 "local a, b = ns.ClassName('PALADIN', true), ns.ClassName('PALADIN') "
                 "LOCALIZED_CLASS_NAMES_MALE.PALADIN = old return a .. '|' .. b")
    assert got == "Paladín|Paladin", got
    # Without the client table: English.
    got = c.eval("local old = LOCALIZED_CLASS_NAMES_MALE LOCALIZED_CLASS_NAMES_MALE = nil "
                 "local a = ns.ClassName('MAGE', true) LOCALIZED_CLASS_NAMES_MALE = old return a")
    assert got == "Mage", got
    assert c.eval("return ns.ClassName('NOPECLASS')") == "Nopeclass"
    assert c.eval("return ns.ClassName('NOPECLASS', true)") == "Nopeclass"
    assert c.eval("return ns.ClassName(nil)") is None
    assert c.eval("return ns.ClassName('')") is None
    assert c.eval("return ns.ClassName(5, true)") is None
    for cls in ("WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"):
        assert c.eval("return ns.ClassName(...)", cls) == c.eval("return ns.CLASS_NAMES[...]", cls)
    no_errors(w)


@case
def every_spec_has_the_raid_comp_icon():
    w, c = solo()
    bad = c.eval_py("""
      local bad = {}
      for cls, specs in pairs(ns.SPECS) do
        for i, s in ipairs(specs) do
          local want = ns.RaidComp:SpecIcon(cls, i)
          if not s.icon or s.icon ~= want then bad[#bad + 1] = cls .. ' ' .. s.label .. ' ' .. tostring(s.icon) end
          if ns.SpecIcon(cls, i) ~= s.icon or ns.SpecIcon(cls, s.label) ~= s.icon then
            bad[#bad + 1] = cls .. ' ' .. s.label .. ': ns.SpecIcon'
          end
          if not tostring(s.icon):find('^Interface\\\\Icons\\\\') then bad[#bad + 1] = cls .. ' ' .. tostring(s.icon) end
        end
      end
      return bad
    """)
    assert bad == [], bad
    assert c.eval("return ns.SPECS.DRUID[3].icon") == "Interface\\Icons\\Ability_Racial_BearForm"
    assert c.eval("return ns.SpecIcon('DRUID', 9)") is None
    assert c.eval("return ns.SpecIcon('NOPE', 1)") is None
    assert c.eval("return ns.SpecIcon(nil, 1)") is None
    no_errors(w)


@case
def profession_list_matches_the_professions_module():
    w, c = solo()
    mine = c.eval_py("local t = {} for i, p in ipairs(ns.PROFESSIONS) do t[i] = { p.id, p.name, p.primary == true } end "
                     "return t")
    theirs = c.eval_py("local t = {} for i, p in ipairs(ns.Professions:GetProfessions()) do "
                       "t[i] = { p.id, p.name, p.primary == true } end return t")
    assert mine == theirs, (mine, theirs)
    assert c.eval("return ns.PROFESSION_IDS.Jewelcrafting") == 755
    assert c.eval("return ns.PROFESSION_NAMES[333]") == "Enchanting"
    # Core/Gems.lua's and Core/BiSExport.lua's ids agree.
    for name, pid in (("Enchanting", 333), ("Engineering", 202), ("Jewelcrafting", 755), ("Leatherworking", 165),
                      ("Tailoring", 197), ("Alchemy", 171), ("Blacksmithing", 164), ("Herbalism", 182),
                      ("Mining", 186), ("Skinning", 393)):
        assert c.eval("return ns.PROFESSION_IDS[...]", name) == pid, name
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# DB:GuildBucket
# ------------------------------------------------------------------------------------------------------------------
@case
def guild_bucket_creates_on_demand_like_the_accessors():
    w, c = solo("Alice")
    gk = c.eval("return ns.Guild:GetGuildKey()")
    assert gk, gk
    # Missing and not asked to create: nil, nothing written.
    assert c.eval("return ns.DB:GuildBucket('zzTest')") is None
    assert c.eval("return ns.db.zzTest") is None
    # create: db[key] and db[key][guild] appear; the same table comes back every time, with the guild key.
    b, g = c.eval("local b, g = ns.DB:GuildBucket('zzTest', true) b.x = 1 return b, g")
    assert g == gk
    assert c.eval("return ns.db.zzTest[...].x", gk) == 1
    assert c.eval("return ns.DB:GuildBucket('zzTest') == ns.db.zzTest[...]", gk) is True
    assert c.eval("return ns.DB:GuildBucket('zzTest', true) == ns.DB:GuildBucket('zzTest')") is True
    # The root exists but not this guild's table: nil without create.
    c.eval("ns.db.zzOther = { ['Elsewhere-Realm'] = { y = 2 } }")
    assert c.eval("return ns.DB:GuildBucket('zzOther')") is None
    # Another guild's bucket by name.
    assert c.eval("return ns.DB:GuildBucket('zzOther', false, 'Elsewhere-Realm').y") == 2
    # A corrupt saved value is left alone without create, replaced with create.
    c.eval("ns.db.zzBad = 5")
    assert c.eval("return ns.DB:GuildBucket('zzBad')") is None
    assert c.eval("return ns.db.zzBad") == 5
    assert c.eval("return type(ns.DB:GuildBucket('zzBad', true))") == "table"
    c.eval("ns.db.zzBad2 = { [ns.Guild:GetGuildKey()] = 'oops' }")
    assert c.eval("return ns.DB:GuildBucket('zzBad2')") is None
    assert c.eval("return type(ns.DB:GuildBucket('zzBad2', true))") == "table"
    # The same table the modules' own accessors use (Events: db.events[guild key]).
    same = c.eval("local r = ns.DB:GuildBucket('events', true) return ns.db.events[ns.Guild:GetGuildKey()] == r")
    assert same is True
    no_errors(w)


@case
def guild_bucket_is_nil_before_the_guild_is_known():
    w, c = solo("Solo", guild=None, tick=3)
    assert c.eval("return ns.Guild:GetGuildKey()") is None
    assert c.eval("return ns.DB:GuildBucket('zzTest', true)") is None
    assert c.eval("return ns.db.zzTest") is None
    # ... and before the saved variables exist.
    assert c.eval("local db = ns.db ns.db = nil local r = ns.DB:GuildBucket('zzTest', true, 'G-R') ns.db = db "
                  "return r") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()
