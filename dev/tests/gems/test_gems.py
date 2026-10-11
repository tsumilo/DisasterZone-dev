#!/usr/bin/env python
"""Gems and enchants on My BiS picks (Core/Gems.lua, Data/Gems.lua, UI/GemEditor.lua), on the real addon.

The setups are stored per item of a list, shared by its phases, flat next to the picks (data.ge = { [itemID] =
"enchant:gem1:gem2:gem3" }, off spec data.oge; omitted when empty), so released validators let them through and the
hash covers them. Covers: the generated data and the game's rules (socket colours, socket bonus, meta gem rules,
which enchants fit which item, ring enchants for Enchanters only); setups in both specs (round trip, sanitizing,
swapping the lists, pruning items that left the list, the raid lock); the guide's suggestions and filling a phase
(empty ones only, or everything); progress counts; a committed list reaches the council with its setups, malformed
setups are rejected, a released 1.3.0 council relays them untouched; the fullest list with a setup on every pick fits
the member wire cap; My BiS shows the strip on a tile, the editor stores a choice and moves to the next empty socket,
the centre counts gems / enchants, the tile's tooltip carries the gems.

Run: luaenv\\Scripts\\python.exe tests\\gems\\test_gems.py   [-k substring]
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, new_world, up, settle, key, own, cached  # noqa: E402

r = Runner("gems and enchants")
RK = key("Raider")

GLOVES = 28506          # Gloves of Dexterous Manipulation: red + blue sockets, +3 Crit (Kara, Attumen)
SHOULDERS = 28755       # Bladed Shoulderpads of the Merciless: yellow + yellow, +3 Hit
NECK = 28731            # Shining Chain of the Afterworld: no sockets, no enchant
RUBY = 24029            # Teardrop Living Ruby (red)
TOPAZ = 24060           # Luminous Noble Topaz (orange: red and yellow)
NIGHTSEYE = 24057       # Royal Nightseye (purple: red and blue)
STAR = 24037            # Lustrous Star of Elune (blue)
INSIGHTFUL = 25901      # Insightful Earthstorm Diamond (meta: 2 red, 2 yellow, 2 blue)
MAJOR_HEALING = 2322    # Enchant Gloves - Major Healing
RING_SPELLPOWER = 2928  # Enchant Ring - Spellpower (Enchanters only)
MAX_WIRE_LEN_MEMBER = 4000
MAX_INFLATED_LEN_MEMBER = 16384


def solo(name="Raider", cls="PALADIN", spec="Holy"):
    w = new_world()
    c = Client(w, name, class_file=cls, guild_rank=3)
    up(c)
    settle(w, 5)
    if spec:
        assert c.eval("return ns.BiS:SetSpec(...)", spec) is True
    return w, c


def setup_of(c, item, lst=None):
    return c.eval_py("local e, g = ns.BiS:GetGemSetup(...) return { e, g }", item, lst)


def data_of(c, owner=None):
    if owner is None:
        return c.eval_py("return ns.BiS:GetData()")
    return c.eval_py("local r = ns.Store:GetCached(...) return r and r.data", owner)


def ge(d, k="ge"):
    t = d.get(k)
    if t is None:
        return None
    if isinstance(t, list):
        return {i + 1: v for i, v in enumerate(t) if v is not None}
    return {int(a): b for a, b in t.items()}


def gems_list(g):
    if isinstance(g, dict):
        return [g.get(i, g.get(str(i), 0)) for i in range(1, 1 + max([int(k) for k in g] or [0]))]
    return list(g or [])


# ------------------------------------------------------------------------------------------------------------------
@r.case
def data_and_rules():
    w, c = solo()
    assert c.eval_py("return { ns.Gems:Sockets(...) }", GLOVES) == [["R", "B"], "+3 Crit"]
    assert c.eval_py("return ns.Gems:Sockets(...)", NECK) in ([], {}, None)
    g = c.eval_py("return ns.Gems:Gem(...)", RUBY)
    assert g["color"] == "R" and g["name"] == "Teardrop Living Ruby" and "18 Healing" in g["text"], g
    assert g["icon"].lower().endswith("inv_jewelcrafting_livingruby_03")
    fits = c.eval_py("""local G = ns.Gems local o = {}
        for _, x in ipairs({ { ..., 'R' }, { select(2, ...), 'R' }, { select(2, ...), 'Y' }, { select(2, ...), 'B' },
                             { select(3, ...), 'B' }, { select(4, ...), 'M' }, { select(4, ...), 'R' } }) do
          o[#o + 1] = G:Fits(x[1], x[2]) end return o""", RUBY, TOPAZ, NIGHTSEYE, INSIGHTFUL)
    assert fits == [True, True, True, False, True, True, False], fits
    # the socket bonus: every socket with a gem of its colour (purple counts as blue)
    assert c.eval("return ns.Gems:BonusActive(..., { select(2, ...), select(3, ...) })", GLOVES, RUBY, NIGHTSEYE) is True
    assert c.eval("return ns.Gems:BonusActive(..., { select(2, ...), select(2, ...) })", GLOVES, RUBY) is False
    assert c.eval("return ns.Gems:BonusActive(..., { select(2, ...) })", GLOVES, RUBY) is False
    # meta rules
    active, words = c.eval("return ns.Gems:MetaState(..., { R = 2, Y = 2, B = 2 })", INSIGHTFUL)
    assert active is True and words == "at least 2 Red, 2 Yellow and 2 Blue gems", words
    assert c.eval("return (ns.Gems:MetaState(..., { R = 3, Y = 1, B = 2 }))", INSIGHTFUL) is False
    assert c.eval("return ns.Gems:MetaState(25893, { B = 2, Y = 2 })") == (False, "more Blue than Yellow gems")
    # enchants: what fits the item, rings only with Enchanting
    assert c.eval("return ns.Gems:EnchantFitsItem(..., select(2, ...))", MAJOR_HEALING, GLOVES) is True
    assert c.eval("return ns.Gems:EnchantFitsItem(..., select(2, ...))", MAJOR_HEALING, SHOULDERS) is False
    assert c.eval("return ns.Gems:CanEnchant(...)", NECK) is False
    ring = 28730                                                 # Mithril Band of the Unscarred
    assert c.eval("return ns.Gems:CanEnchant(..., {})", ring) is False
    assert c.eval("return ns.Gems:CanEnchant(..., { Enchanting = true })", ring) is True
    assert RING_SPELLPOWER in (c.eval_py("return ns.Gems:EnchantsFor(..., { Enchanting = true })", ring) or [])
    names = c.eval_py("local o = {} for _, id in ipairs(ns.Gems:EnchantsFor(...)) do o[#o + 1] = ns.Gems:Enchant(id).short "
                      "end return o", GLOVES)
    assert "Major Healing" in names and "Threat" in names and not any("Shield" in n for n in names), names
    # the item string with a setup
    assert c.eval("return ns.Gems:Link(..., select(2, ...), { select(3, ...) })", GLOVES, MAJOR_HEALING, RUBY) \
        == "item:%d:%d:%d::::::70" % (GLOVES, MAJOR_HEALING, RUBY)
    w.assert_no_errors()


@r.case
def setups_round_trip_in_both_specs():
    w, c = solo()
    live = c.eval("return ns.Util.Hash(ns.BiS:GetData())")
    assert c.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    assert c.eval("return ns.BiS:SetGemSetup(..., select(2, ...), { select(3, ...), 0 })", GLOVES, MAJOR_HEALING, RUBY)
    assert ge(data_of(c)) == {GLOVES: "%d:%d" % (MAJOR_HEALING, RUBY)}, data_of(c).get("ge")
    e, g = setup_of(c, GLOVES)
    assert e == MAJOR_HEALING and gems_list(g)[:1] == [RUBY], (e, g)
    assert c.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    # the view and the doll read it
    assert c.eval("return ns.Gems:LinkFor(ns.BiS:GetListView(), ...)", GLOVES).startswith("item:%d:%d:%d" % (
        GLOVES, MAJOR_HEALING, RUBY))
    # the off spec has its own
    assert c.eval("return ns.BiS:AddOffSpec('Protection')") is True
    assert c.eval("return ns.BiS:SetSlot(2, 7, 'main', ..., 'os')", GLOVES) is True
    assert c.eval("return ns.BiS:SetGemSetup(..., 0, { 0, select(2, ...) }, 'os')", GLOVES, STAR) is True
    d = data_of(c)
    assert ge(d, "oge") == {GLOVES: "0:0:%d" % STAR} and ge(d) == {GLOVES: "%d:%d" % (MAJOR_HEALING, RUBY)}, d
    assert c.eval("return ns.ListView(ns.BiS:GetData(), 'os').ge[...]", GLOVES) == "0:0:%d" % STAR
    # swapping the lists swaps the setups
    assert c.eval("return ns.BiS:SwapLists()") is True
    d = data_of(c)
    assert ge(d) == {GLOVES: "0:0:%d" % STAR} and ge(d, "oge") == {GLOVES: "%d:%d" % (MAJOR_HEALING, RUBY)}, d
    assert c.eval("return ns.BiS:SwapLists()") is True
    # removing the off spec drops its setups
    assert c.eval("return ns.BiS:RemoveOffSpec()") is True
    assert "oge" not in data_of(c)
    # an item that leaves the list takes its setup along
    assert c.eval("return ns.BiS:ClearSlot(1, 7)") is True
    assert "ge" not in data_of(c)
    assert c.eval("return ns.Util.Hash(ns.BiS:GetData())") == live, "an emptied setup table changed the hash"
    # a setup for an item not on the list is not kept
    assert c.eval("return ns.BiS:SetGemSetup(..., select(2, ...))", SHOULDERS, MAJOR_HEALING) is True
    assert "ge" not in data_of(c)
    # clearing
    assert c.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    c.eval("ns.BiS:SetGemSetup(..., select(2, ...), {})", GLOVES, MAJOR_HEALING)
    assert ge(data_of(c)) == {GLOVES: str(MAJOR_HEALING)}
    c.eval("ns.BiS:SetGemSetup(...)", GLOVES)
    assert "ge" not in data_of(c)
    # sanitizing what a SavedVariables edit could leave
    c.eval("""local d = ns.BiS:GetData()
        d.ge = { [...] = '2322:24029:0:0', [0] = '1', [12] = 'x', [28755] = '0:0', [28730] = '1:2:3:4:5:6:7' }
        d.oge = { [28506] = 5 }""", GLOVES)
    c.relog()
    settle(w, 3)
    d = data_of(c)
    assert ge(d) == {GLOVES: "2322:24029"}, d.get("ge")
    assert "oge" not in d, d
    w.assert_no_errors()


@r.case
def lock_refuses_setup_edits():
    w, c = solo()
    assert c.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    c.eval("ns.GroupRules.IsLocked = function() return true end ns.GroupRules.GetLockInfo = function() return nil end")
    assert c.eval("return ns.BiS:SetGemSetups({ [...] = { enchant = 2322 } })", GLOVES) is False
    assert c.eval("return ns.Gems:FillPhase(1)") is False
    assert "ge" not in data_of(c)
    w.assert_no_errors()


@r.case
def suggestions_and_filling_a_phase():
    w, c = solo(spec="Retribution")
    assert c.eval("return ns.Gems:GuideFor(ns.BiS:GetListView())") == "PaladinRetribution"
    gd = "ns.Gems:GuideData('PaladinRetribution', 1)"
    # the sims' gems, ranked by the spec's weights (strength over a stamina / attack power gem)
    names = c.eval_py("local G = ns.Gems local o = {} for _, id in ipairs(G:Candidates(" + gd + ", 1, {})) do "
                      "o[#o + 1] = G:Gem(id).name end return o")
    assert names[:2] == ["Bold Living Ruby", "Inscribed Noble Topaz"] and "Sovereign Nightseye" in names, names
    assert not any(n.startswith("Rigid") for n in names), names          # hit: the sims don't gem it
    # Crystalforge Breastplate (red, yellow, yellow; +4 Strength) in P2: the unique Fire Opal goes in a yellow socket,
    # every socket matches (the bonus is worth it): the best total by the weights
    g = c.eval_py("local G = ns.Gems local gd = G:GuideData('PaladinRetribution', 2) "
                  "local g, bonus = G:BestGems(30129, gd, 2, {}, {}) return { g, bonus }")
    gems, bonus = gems_list(g[0]), g[1]
    assert bonus is True and gems[1] == 30584 or gems[2] == 30584, gems
    assert gems.count(30584) == 1, gems
    def sug(item, sid, phase=1, profs="{}", used="{}"):
        return c.eval_py("local e, g = ns.Gems:Suggest(..., select(2, ...), 'PaladinRetribution', select(3, ...), "
                         + profs + ", " + used + ") return { e, g }", item, sid, phase)
    # yellow sockets: the topaz (bonus); red + blue with a small crit bonus: two rubies are worth more
    assert gems_list(sug(SHOULDERS, 3)[1]) == [24058, 24058]
    assert gems_list(sug(GLOVES, 7)[1]) == [24027, 24027]
    # meta socket: the sims' meta gem; enchants: the sims' per slot
    helm = 29073
    e, g = sug(helm, 1)
    assert gems_list(g) == [24027, 32409] and e == 3003, (e, g)
    assert sug(SHOULDERS, 3)[0] == 2986
    # a unique gem goes in once: none of the suggestions repeat one, and one already used is skipped
    uniq = c.eval("for id, r in pairs(ns.Data.Gems) do if r.u and r[1] == 'R' and r[3] <= 1 then return id end end")
    got = c.eval_py("local used = {} local o = {} for i = 1, 3 do local _, g = ns.Gems:Suggest(..., 7, "
                    "'PaladinRetribution', 1, {}, used) o[#o + 1] = g end return o", GLOVES)
    flat = [x for g in got for x in gems_list(g)]
    uniques = [x for x in flat if c.eval("return ns.Data.Gems[...].u", x)]
    assert len(uniques) == len(set(uniques)), flat
    assert uniq not in flat
    # ring enchants only for Enchanters
    ring = 28730
    assert c.eval("return (ns.Gems:Suggest(..., 11, 'PaladinRetribution', 5, {}))", ring) == 0
    assert c.eval("return (ns.Gems:Suggest(..., 11, 'PaladinRetribution', 5, { Enchanting = true }))", ring) == 2931
    # filling a phase: the empty ones only, then everything
    assert c.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    assert c.eval("return ns.BiS:SetSlot(1, 3, 'main', ...)", SHOULDERS) is True
    assert c.eval("return ns.BiS:SetSlot(1, 2, 'main', ...)", NECK) is True
    c.eval("ns.BiS:SetGemSetup(..., 0, { 0, select(2, ...) })", GLOVES, STAR)
    assert c.eval("return ns.Gems:FillPhase(1)") == 2
    d = ge(data_of(c))
    assert d[GLOVES] == "684:24027:%d" % STAR, d                # my blue gem stayed
    # the shoulders: a green gem (yellow and blue) + the topaz: with the gloves' ruby and blue gem that is 2 red,
    # 2 yellow and 2 blue for Relentless Earthstorm Diamond, and the yellow sockets keep their bonus
    assert d[SHOULDERS] == "2986:24067:24058", d
    assert NECK not in d
    assert c.eval("return ns.Gems:FillPhase(1)") == 0
    assert c.eval("return ns.Gems:FillPhase(1, nil, true)") >= 1
    assert ge(data_of(c))[GLOVES].startswith("684:24027:")
    # no spec: no guide, nothing filled
    c.eval("ns.BiS:GetData().sp = ''")
    assert c.eval("return ns.Gems:FillPhase(1)") is None
    w.assert_no_errors()


@r.case
def progress_counts():
    w, c = solo()
    for sid, item in ((7, GLOVES), (3, SHOULDERS), (2, NECK)):
        assert c.eval("return ns.BiS:SetSlot(1, ..., 'main', select(2, ...))", sid, item) is True
    prog = c.eval("return ns.Gems:Progress(ns.BiS:GetListView(), 1)")
    assert prog == (0, 4, 0, 2), prog
    c.eval("ns.BiS:SetGemSetup(..., select(2, ...), { select(3, ...) })", GLOVES, MAJOR_HEALING, RUBY)
    assert c.eval("return ns.Gems:Progress(ns.BiS:GetListView(), 1)") == (1, 4, 1, 2)
    # a disabled slot does not count
    assert c.eval("return ns.BiS:SetSlotDisabled(1, 3, true)") is True
    assert c.eval("return ns.Gems:Progress(ns.BiS:GetListView(), 1, function(sid) return ns.BiS:IsSlotDisabled(1, sid) end)") \
        == (1, 2, 1, 1)
    w.assert_no_errors()


REPO = os.path.dirname(os.path.dirname(TESTS))
DIST_130 = os.path.join(REPO, "dist", "DisasterZone-1.3.0.zip")
UNPACKED_130 = os.path.join(os.path.dirname(TESTS), "tf_e", "_addon130")     # (shared with tests/preraid)


def addon_130():
    """The released 1.3.0 addon folder (unpacked by tests/preraid on first use), or None."""
    folder = os.path.join(UNPACKED_130, "DisasterZone")
    if os.path.exists(os.path.join(folder, "DisasterZone.toc")):
        return folder
    if not os.path.exists(DIST_130):
        return None
    import zipfile
    tmp = "%s.%d.tmp" % (UNPACKED_130, os.getpid())
    with zipfile.ZipFile(DIST_130) as z:
        z.extractall(tmp)
    try:
        os.rename(tmp, UNPACKED_130)
    except OSError:
        pass
    return folder


def trio(c1_dir=None):
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1, addon_dir=c1_dir)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=False)
    for c in (R, C1):
        up(c)
    return w, R, C1, C2


@r.case
def setups_reach_the_council_and_bad_ones_are_rejected():
    w, R, C1, _ = trio()
    settle(w, 30)
    assert R.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    R.eval("ns.BiS:SetGemSetup(..., select(2, ...), { select(3, ...), select(4, ...) })", GLOVES, MAJOR_HEALING, RUBY,
           NIGHTSEYE)
    R.eval("ns.BiS:Commit()")
    settle(w, 6)
    o = own(R)
    c = cached(C1, RK)
    assert c and c["rev"] == o["rev"] and c["hash"] == o["hash"], (c, o)
    assert ge(data_of(C1, RK)) == {GLOVES: "%d:%d:%d" % (MAJOR_HEALING, RUBY, NIGHTSEYE)}
    # the council's doll reads the member's setup
    link = C1.eval("local r = ns.Store:GetCached(...) return ns.Gems:LinkFor(r.data, select(2, ...))", RK, GLOVES)
    assert link and link.startswith("item:%d:%d:%d:%d" % (GLOVES, MAJOR_HEALING, RUBY, NIGHTSEYE)), link
    # malformed setups are rejected
    for bad in ("{ [28506] = 5 }", "{ [28506] = 'a:b' }", "{ [0] = '1' }", "{ [28506] = '1|2' }", "'x'"):
        ok = R.eval("local d = ns.Util.CopyTable(ns.BiS:GetData()) d.ge = " + bad + " return ns.Store:ValidateData(d)")
        assert ok is not True, bad
    w.assert_no_errors()


@r.case
def released_1_3_0_council_relays_setups_untouched():
    old = addon_130()
    if old is None:
        r.note("SKIPPED: %s is missing" % DIST_130)
        return
    w, R, O, _ = trio(c1_dir=old)
    settle(w, 30)
    assert O.eval("return ns.Gems") is None, "Councila does not run the released 1.3.0 code"
    assert R.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    R.eval("ns.BiS:SetGemSetup(..., select(2, ...), { select(3, ...) })", GLOVES, MAJOR_HEALING, RUBY)
    R.eval("ns.BiS:Commit()")
    settle(w, 6)
    o = own(R)
    c = cached(O, RK)
    assert c and c["rev"] == o["rev"] and c["hash"] == o["hash"] == c["live"], (c, o)
    assert ge(data_of(O, RK)) == {GLOVES: "%d:%d" % (MAJOR_HEALING, RUBY)}
    w.assert_no_errors()


SIZE_LUA = r"""
  local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
  local rec = ns.BiS:GetRecord()
  local s = LS:Serialize({ t = 'L', r = rec.rev, ts = rec.ts, h = rec.hash, d = rec.data })
  return 1 + #LD:EncodeForWoWAddonChannel(LD:CompressDeflate(s)), #s
"""


@r.case
def fullest_list_with_setups_fits_the_member_cap():
    w, R, C1, _ = trio()
    settle(w, 30)
    rnd = random.Random(11)
    ids = rnd.sample(range(100000, 200001), 408)
    # two specs' worth of gems and enchants (a guide suggests 2-6 gems a phase): 10 gems, 16 enchants
    gem_ids = R.eval_py("local o = {} for id in pairs(ns.Data.Gems) do o[#o + 1] = id end table.sort(o) return o")[::21][:10]
    ench_ids = R.eval_py("local o = {} for id in pairs(ns.Data.Enchants) do o[#o + 1] = id end table.sort(o) return o")[::8][:16]
    R.eval(r"""
      local ids, gems, enchants, seed = ...
      local n = 0
      local function nid() n = n + 1 return ids[n] end
      local function slots() local t = {} for sid = 1, 17 do t[sid] = { nid(), nid() } end return t end
      local d = ns.BiS:GetData()
      d.ph, d.op = {}, {}
      for p = 1, 5 do d.ph[p] = slots() d.op[p] = slots() end
      d.pr, d.opr = slots(), slots()
      d.sp, d.os = 'Holy', 'Protection'
      -- a 3-gem setup with an enchant on every item of both lists
      local k = 0
      local function pick(t) k = k + 7 return t[(k % #t) + 1] end   -- (7: never the same setup twice in a row)
      d.ge, d.oge = {}, {}
      for i = 1, 204 do d.ge[ids[i]] = pick(enchants) .. ':' .. pick(gems) .. ':' .. pick(gems) .. ':' .. pick(gems) end
      for i = 205, 408 do d.oge[ids[i]] = pick(enchants) .. ':' .. pick(gems) .. ':' .. pick(gems) .. ':' .. pick(gems) end
      local rec = ns.BiS:GetRecord()
      for i = 1, 200 do rec.manual[ids[i]] = true end
      ns.BiS:RebuildDerived()
      ns.BiS:MarkDirty()
    """, ids, gem_ids, ench_ids)
    R.eval("ns.BiS:Commit()")
    wire, inflated = R.eval(SIZE_LUA)
    r.note("fullest list with a setup on all 408 picks: %d bytes on the wire, %d inflated" % (wire, inflated))
    assert wire < MAX_WIRE_LEN_MEMBER and inflated < MAX_INFLATED_LEN_MEMBER, (wire, inflated)
    settle(w, 6)
    o = own(R)
    c = cached(C1, RK)
    assert c and c["rev"] == o["rev"] and c["hash"] == o["hash"], (c, o)
    w.assert_no_errors()


@r.case
def my_bis_strip_editor_and_centre():
    w, c = solo()
    for sid, item in ((7, GLOVES), (3, SHOULDERS), (2, NECK)):
        assert c.eval("return ns.BiS:SetSlot(1, ..., 'main', select(2, ...))", sid, item) is True
    c.eval("ns.MyBiS:SetPhase(1, true)")
    c.eval("ns.MainFrame:Open('mybis')")
    settle(w, 1)
    c.eval("ns.MyBiS:Refresh()")
    # the doll is local to My BiS: find its tiles in the frame tree
    shown = c.eval_py("""
        local o = {}
        local function walk(f)
          if f.strip and f.sid then o[#o + 1] = { f.sid, f.strip:IsShown() and 1 or 0, f.strip:GetWidth() } __GT = __GT or {} __GT[f.sid] = f end
          for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end
        end
        walk(UIParent)
        table.sort(o, function(a, b) return a[1] < b[1] end)
        return o""")
    by = {s: (vis, wd) for s, vis, wd in shown}
    assert by[7][0] == 1 and by[3][0] == 1, by       # sockets + an enchant
    assert by[2][0] == 0, by                         # the neck takes neither
    # the centre counts them
    assert c.eval("return ns.MyBiS:GetFinish()") == (True, "4 gems, 2 enchants to choose")
    # the gloves' strip opens the editor on the red socket
    c.eval("T_STRIP = __GT[7].strip")
    c.click("T_STRIP")
    settle(w, 0.2)
    f, st = c.eval_py("local f, s = ns.GemEditor:GetFrame() return { f and f:IsShown(), { target = s.target, item = s.itemID } }")
    assert f is True and st["target"] == "s1" and st["item"] == GLOVES, (f, st)
    assert c.find_text("Red socket")
    assert c.find_text("Socket bonus: +3 Crit")
    # the first choice is the guide's best (Teardrop Living Ruby); picking it moves on to the blue socket
    first = c.eval_py("local f = ns.GemEditor:GetFrame() local b = f.choices[1] return { b.id, b.tag:GetText() }")
    assert first == [RUBY, "Best"], first
    c.eval("T_CHOICE = ns.GemEditor:GetFrame().choices[1]")
    c.click("T_CHOICE")
    settle(w, 0.2)
    e, g = setup_of(c, GLOVES)
    assert gems_list(g)[:1] == [RUBY], g
    assert c.eval("local _, s = ns.GemEditor:GetFrame() return s.target") == "s2"
    # Use suggested fills the rest (enchant too); the strip and the centre follow
    c.eval("T_SUG = ns.GemEditor:GetFrame().suggest")
    c.click("T_SUG")
    settle(w, 0.3)
    e, g = setup_of(c, GLOVES)
    assert e == MAJOR_HEALING and gems_list(g) == [RUBY, RUBY], (e, g)
    assert c.eval("return ns.MyBiS:GetFinish()") == (True, "2 gems, 1 enchant to choose")
    # the tile's tooltip shows the item with its gems
    link = c.eval("return __GT[7].mainLink")
    assert link == "item:%d:%d:%d:%d:::::70" % (GLOVES, MAJOR_HEALING, RUBY, RUBY), link
    # search looks through every gem
    c.eval("T_SEARCH = ns.GemEditor:GetFrame().search")
    c.type_text("T_SEARCH", "nightseye")
    settle(w, 0.5)
    ids = c.eval_py("local f = ns.GemEditor:GetFrame() local o = {} for _, b in ipairs(f.choices) do if b:IsShown() then o[#o + 1] = b.id end end return o")
    assert NIGHTSEYE in ids, ids
    # Clear, then Escape closes it
    c.eval("T_CLEAR = ns.GemEditor:GetFrame().clear")
    c.click("T_CLEAR")
    settle(w, 0.2)
    assert "ge" not in data_of(c) or GLOVES not in (ge(data_of(c)) or {})
    c.eval("ns.GemEditor:Close()")
    assert c.eval("return ns.GemEditor:IsShown()") is False
    # the Suggest menu fills the phase
    c.eval("ns.Gems:FillPhase(1)")
    settle(w, 0.3)
    assert c.eval("return ns.MyBiS:GetFinish()") == (False, ""), c.eval("return ns.MyBiS:GetFinish()")
    w.assert_no_errors()


@r.case
def import_and_export_carry_gems_and_enchants():
    w, c = solo()
    # WoWSims "Addon" JSON: gear.items in slot order, enchant = the enchant number, gems = item ids
    items = ["null"] * 17
    items[6] = '{"id": %d, "enchant": %d, "gems": [%d, %d]}' % (GLOVES, MAJOR_HEALING, RUBY, STAR)
    items[2] = '{"id": %d, "gems": [%d]}' % (SHOULDERS, TOPAZ)
    text = '{"class": "paladin", "gear": {"items": [%s]}}' % ", ".join(items)
    n = c.eval("""local p = assert(ns.BiSImport:Parse(...)) local plan = ns.BiSImport:Plan(p, {})
        return ns.BiSImport:Apply(plan, 1, false, false), plan.gemCount""", text)
    assert n == (2, 2), n
    d = ge(data_of(c))
    assert d == {GLOVES: "%d:%d:%d" % (MAJOR_HEALING, RUBY, STAR), SHOULDERS: "0:%d" % TOPAZ}, d
    # Sixty Upgrades: the enchant as a table with the craft's spell, gems as tables
    su = ('{"character": {"name": "X", "gameClass": "PALADIN"}, "items": [{"id": %d, "slot": "HANDS", '
          '"enchant": {"spellId": 33999}, "gems": [{"id": %d}, {"id": %d}]}]}' % (GLOVES, NIGHTSEYE, NIGHTSEYE))
    c.eval("""local p = assert(ns.BiSImport:Parse(...)) ns.BiSImport:Apply(ns.BiSImport:Plan(p, {}), 2, true, false)""", su)
    assert ge(data_of(c))[GLOVES] == "%d:%d:%d" % (MAJOR_HEALING, NIGHTSEYE, NIGHTSEYE)   # Replace: over the old one
    # Fill keeps an item's own setup
    c.eval("""local p = assert(ns.BiSImport:Parse(...)) ns.BiSImport:Apply(ns.BiSImport:Plan(p, {}), 3, false, false)""", text)
    assert ge(data_of(c))[GLOVES] == "%d:%d:%d" % (MAJOR_HEALING, NIGHTSEYE, NIGHTSEYE)
    # export: the planned setup goes out (WoWSims JSON, Bulk, Wowhead with the enchant's spell), and reads back in
    specs = c.eval_py("local s = ns.BiSExport:PhaseSpecs(1) return s")
    g = specs[7] if isinstance(specs, list) else specs.get(7, specs.get("7"))
    assert g["enchant"] == MAJOR_HEALING and gems_list(g["gems"]) == [NIGHTSEYE, NIGHTSEYE] and g["enchantSpell"] == 33999, g
    js = c.eval("return ns.BiSExport:WoWSims(ns.BiSExport:PhaseSpecs(1))")
    assert '"enchant":%d' % MAJOR_HEALING in js.replace(" ", ""), js[:300]
    link = c.eval("return ns.BiSExport:WowheadLink(ns.BiSExport:PhaseSpecs(1))")
    c.eval("ns.BiS:ClearPhase(1) ns.BiS:ClearPhase(2) ns.BiS:ClearPhase(3)")
    assert "ge" not in data_of(c)
    c.eval("""local p = assert(ns.BiSImport:Parse(...)) ns.BiSImport:Apply(ns.BiSImport:Plan(p, {}), 1, true, false)""", link)
    assert ge(data_of(c)) == {GLOVES: "%d:%d:%d" % (MAJOR_HEALING, NIGHTSEYE, NIGHTSEYE), SHOULDERS: "0:%d" % TOPAZ},         data_of(c).get("ge")
    w.assert_no_errors()


@r.case
def shopping_list_gets_the_crafts():
    w, c = solo()
    assert c.eval("return ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES) is True
    assert c.eval("return ns.BiS:SetSlot(1, 3, 'main', ...)", SHOULDERS) is True
    c.eval("ns.BiS:SetGemSetup(..., select(2, ...), { select(3, ...), select(3, ...) })", GLOVES, MAJOR_HEALING, RUBY)
    c.eval("ns.BiS:SetGemSetup(..., 3001, { select(2, ...) })", SHOULDERS, RUBY)      # Glyph of Renewal: reputation
    needs, other = c.eval_py("local n, o = ns.Gems:ShoppingNeeds(1) return { n, o }")
    needs = {int(k): v for k, v in (needs.items() if isinstance(needs, dict) else enumerate(needs, 1)) if v}
    assert needs.get(RUBY) == 3 and needs.get(-33999) == 1 and other == 1, (needs, other)
    n, other = c.eval("return ns.Gems:AddToShoppingList(1)")
    assert n == 4 and other == 1, (n, other)
    assert c.eval("return ns.Shop:GetAmount(...)", RUBY) == 3
    assert c.eval("return ns.Shop:GetAmount(-33999)") == 1
    # crafted picks I don't have yet go on it too (Spellstrike Hood, Tailoring)
    assert c.eval("return ns.BiS:SetSlot(1, 1, 'main', 24266)") is True
    assert c.eval("return ns.Shop:CanAdd(24266)") is True
    needs = c.eval_py("return (ns.Gems:ShoppingNeeds(1))")
    needs = {int(k): v for k, v in (needs.items() if isinstance(needs, dict) else enumerate(needs, 1)) if v}
    assert needs.get(24266) == 1, needs
    w.assert_no_errors()


@r.case
def filling_a_phase_keeps_the_meta_gem_active():
    w, c = solo(spec="Retribution")
    for ph in (1, 2, 3):
        res = c.eval_py("""local ph = ...
            ns.BiS:ApplyTemplate(ph, ns.Loon:GetTemplate('PALADIN', 'Retribution', ph), true)
            ns.Gems:FillPhase(ph, nil, true)
            local G, view = ns.Gems, ns.BiS:GetListView()
            local counts, meta, uniques, dup = G:ColorCounts(view, ph), nil, {}, false
            for _, id in pairs(G:CountedPicks(view, ph)) do
              local _, g = G:GetSetup(view, id)
              for _, x in pairs(g) do
                local gem = G:Gem(x)
                if gem and gem.color == 'M' then meta = x end
                if gem and gem.unique then if uniques[x] then dup = true end uniques[x] = true end
              end
            end
            return { meta or 0, (G:MetaState(meta or 0, counts)), counts.B, dup }""", ph)
        meta, active, blue, dup = res
        assert meta == 32409 and active is True and blue >= 2 and not dup, (ph, res)
    # the cheapest way: P1's two blue gems go where they keep a socket bonus
    w.assert_no_errors()


CRIMSON = 32195         # Teardrop Crimson Spinel (epic red, P3)
GARNET = 23094          # Teardrop Blood Garnet (uncommon red)
TANZANITE = 30603       # Royal Tanzanite (unique epic purple, P1)
CROWN = 28193           # Mana-Etched Crown: red + meta


def gem_qualities(c, ph):
    """The phase's gems: { meta, meta active, best non-meta quality, non-meta count, the setups }."""
    return c.eval_py("""local ph = ...
        local G, view = ns.Gems, ns.BiS:GetListView()
        local counts, meta, top, n = G:ColorCounts(view, ph), nil, 0, 0
        for sid = 1, 17 do
          local id = ns.BiS:GetSlot(ph, sid)
          if id then
            local _, g = G:GetSetup(view, id)
            for _, x in pairs(g) do
              local gem = G:Gem(x)
              if gem and gem.color == 'M' then meta = x elseif gem then
                n = n + 1
                if gem.quality > top then top = gem.quality end
              end
            end
          end
        end
        local ge = {}
        for k, v in pairs(ns.BiS:GetData().ge or {}) do ge[#ge + 1] = k .. '=' .. v end
        table.sort(ge)
        return { meta or 0, (G:MetaState(meta or 0, counts)) and true or false, top, n, table.concat(ge, ' ') }""", ph)


@r.case
def gem_quality_epic_rare_uncommon():
    """Feedback #4: Suggest keeps to Rare / Uncommon gems (my choice per list), the engine finds the strongest gems of
    that quality and the meta gem still gets its colours; the editor's switch shows one quality's gems."""
    w, c = solo()
    # the same cut at a lower quality: plain (not unique), out in the phase; a meta gem stays
    def at(gem, q, ph):
        return c.eval("return ns.Gems:AtQuality(...)", gem, q, ph)
    assert at(CRIMSON, 3, 3) == RUBY and at(CRIMSON, 2, 3) == GARNET and at(RUBY, 4, 1) == RUBY
    assert at(TANZANITE, 3, 1) == NIGHTSEYE and at(INSIGHTFUL, 2, 1) == INSIGHTFUL
    # my choice per list, never synced; Epic = no limit
    assert c.eval("return ns.Gems:GetQuality()") == 4
    c.eval("ns.Gems:SetQuality(2)")
    assert c.eval("return ns.Gems:GetQuality()") == 2 and c.eval("return ns.Gems:GetQuality('os')") == 4
    c.eval("ns.Gems:SetQuality(4)")
    assert c.eval("return ns.db.gemQuality[ns.Util.PlayerKey()]") is None
    # filling at each quality: nothing better than it, the meta active; each quality gives other gems
    for ph in (1, 3):
        c.eval("local ph = ... ns.BiS:ApplyTemplate(ph, ns.Loon:GetTemplate('PALADIN', 'Holy', ph), true)", ph)
        seen = set()
        for q in (4, 3, 2):
            c.eval("ns.Gems:FillPhase(...)", ph, None, True, q)
            meta, active, top, n, setups = gem_qualities(c, ph)
            assert n > 0 and top <= q and meta and active is True, (ph, q, meta, active, top, n)
            if ph == 3 or q == 2:                  # (P1's best gems are rare already: Epic = Rare there)
                assert setups not in seen, (ph, q)
            seen.add(setups)
        # the stored choice is what the plain fill uses
        c.eval("ns.Gems:SetQuality(3)")
        c.eval("ns.Gems:FillPhase(...)", ph, None, True)
        assert gem_qualities(c, ph)[2] == 3, ph
        c.eval("ns.Gems:SetQuality(4)")
    # the editor: the switch starts on the socket's gem (an empty one: Suggest's gem there), Uncommon shows uncommon
    # gems only, a search looks through all of them, a meta socket has no switch
    c.eval("ns.BiS:SetSlot(1, 7, 'main', ...)", GLOVES)
    c.eval("ns.BiS:SetGemSetup(..., 0, { select(2, ...), 0 })", GLOVES, RUBY)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", CROWN)
    c.eval("ns.MyBiS:SetPhase(1, true)")
    c.eval("ns.MainFrame:Open('mybis')")
    settle(w, 1)
    c.eval("ns.MyBiS:Refresh()")
    open_on = ("local sid = ... T_TILE = nil local function walk(f) if f.strip and f.sid == sid and f.mainID then "
               "T_TILE = f end for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end walk(UIParent) "
               "ns.GemEditor:Open(T_TILE, T_TILE.mainID, 1)")
    c.eval(open_on, 7)
    settle(w, 0.2)
    st = c.eval_py("local f, s = ns.GemEditor:GetFrame() return { s.target, s.quality, f.quality[1]:IsShown() }")
    assert st == ["s2", 3, True], st
    c.eval("T_UNC = ns.GemEditor:GetFrame().quality[3]")
    c.click("T_UNC")
    settle(w, 0.2)
    qs = c.eval_py("local f = ns.GemEditor:GetFrame() local o = {} for _, b in ipairs(f.choices) do "
                   "if b:IsShown() then o[#o + 1] = ns.Gems:Gem(b.id).quality end end return o")
    assert qs and set(qs) == {2}, qs
    c.eval("local f, s = ns.GemEditor:GetFrame() s.target = 's1' ns.GemEditor:Refresh()")
    assert c.eval("local _, s = ns.GemEditor:GetFrame() return s.quality") == 3     # the ruby in it
    c.eval("T_SEARCH = ns.GemEditor:GetFrame().search")
    c.type_text("T_SEARCH", "crimson spinel")
    settle(w, 0.5)
    ids = c.eval_py("local f = ns.GemEditor:GetFrame() local o = {} for _, b in ipairs(f.choices) do "
                    "if b:IsShown() then o[#o + 1] = b.id end end return o")
    assert CRIMSON in ids, ids
    c.eval("ns.GemEditor:Close()")
    c.eval(open_on, 1)
    settle(w, 0.2)
    c.eval("local f, s = ns.GemEditor:GetFrame() s.target = 's2' ns.GemEditor:Refresh()")
    meta = c.eval_py("local f, s = ns.GemEditor:GetFrame() return { ns.Gems:Sockets(s.itemID)[2], f.quality[1]:IsShown() }")
    assert meta == ["M", False], meta
    c.eval("ns.GemEditor:Close()")
    # the Suggest menu: picking a quality is a setting, the menu stays open on it
    c.eval("""T_SUGGEST = nil local function walk(f) local fs = f.GetFontString and f:GetFontString()
              if fs and fs:GetText() == 'Suggest' and f:IsVisible() then T_SUGGEST = f end
              for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end walk(UIParent)""")
    c.click("T_SUGGEST")
    settle(w, 0.2)
    c.eval("""T_ROW = nil for _, r in ipairs(ns.UI:GetMenuFrames()[1].rows) do
              if r:IsShown() and (r.fs:GetText() or ''):find('Rare gems', 1, true) then T_ROW = r end end""")
    c.click("T_ROW")
    settle(w, 0.2)
    assert c.eval("return ns.Gems:GetQuality()") == 3
    assert c.eval("local m = ns.UI:GetMenuFrames()[1] return m and m:IsShown() or false") is True
    assert c.eval("return ns.UI:GetMenuFrames()[1].rows[1]:IsShown()") is True
    c.eval("ns.UI:CloseMenus() ns.Gems:SetQuality(4)")
    w.assert_no_errors()


r.run()
