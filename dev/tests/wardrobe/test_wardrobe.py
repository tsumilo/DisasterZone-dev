#!/usr/bin/env python
"""Gear > Wardrobe (Core/Wardrobe.lua, UI/Wardrobe.lua), on the real addon.

Covers: Save what I'm wearing snapshots the 17 slots (shirt and tabard left out, an empty off hand saved empty, the
link's enchant and gems kept); the status of each slot (worn / from the bags / in the bank as last seen / missing /
keep current); Wear swaps only the slots that differ, one move at a time, and says what it did; keep current is never
touched; a swap asked in combat waits for the fight to end; a two-hander empties the off hand first and a one-hander
+ shield go on main hand first; the bank's pieces come out into the bags while it is open; the rules (spec switch,
boss target and back after the kill, fishing pole and back, mounted and back); demo mode shows made-up outfits and
Wear there moves nothing and saves nothing; the page, picker, icon picker and quick-swap bar build without Lua errors.

The mock does not move items itself: W.Move is replaced by one that swaps the two places in __MOCK and fires the
game's events, and records each move.

Run: luaenv\\Scripts\\python.exe tests\\wardrobe\\test_wardrobe.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, new_world, up, settle, assert_no_lua_errors, printed  # noqa: E402

r = Runner("wardrobe (Gear > Wardrobe)")

# WoWSims' P1 Retribution preset, by inventory slot (Lionheart Champion: a two-hander; no off hand)
P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
      11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}
LIONHEART, KINGS_DEFENDER, ALDORI_SHIELD = 28429, 28749, 28825
JUSTICAR_FACE, JUSTICAR_CHEST, GILDED_CLOAK = 29068, 29066, 28660
POLE = 19970

MOVER = """
  local M = __MOCK
  local function get(l)
    if l.inv then return M.inv[l.inv] end
    local b = M.bags[l.bag]; local s = b and b.slots[l.slot]; return s and s.id
  end
  local function set(l, id)
    if l.inv then M.inv[l.inv] = id; return end
    local b = M.bags[l.bag]
    if not b then b = { slots = {}, size = 16 }; M.bags[l.bag] = b end
    b.slots[l.slot] = id and { id = id, count = 1 } or nil
  end
  __moves = {}
  ns.Wardrobe.Move = function(src, dst)
    local a, b = get(src), get(dst)
    set(dst, a); set(src, b)
    __moves[#__moves + 1] = (src.inv and ('i' .. src.inv) or (src.bag .. ':' .. src.slot)) .. '>' ..
      (dst.inv and ('i' .. dst.inv) or (dst.bag .. ':' .. dst.slot))
    for _, l in ipairs({ src, dst }) do if l.inv then M.fire('PLAYER_EQUIPMENT_CHANGED', l.inv, M.inv[l.inv] == nil) end end
    M.fire('BAG_UPDATE_DELAYED')
  end
"""


def solo(gear=P1, bags=None):
    w = new_world()
    c = Client(w, "Raider", class_file="PALADIN", race="BloodElf", guild_rank=3)
    up(c)
    settle(w, 5)
    c.equip(gear)
    c.set_bags(bags or {})
    c.eval(MOVER)
    settle(w, 0.5)
    return w, c


def moves(c):
    return c.eval_py("return __moves") or []


def slots(d):
    """A Lua slots table from {inv: id | False | None (keep)}."""
    parts = []
    for inv, v in d.items():
        if v is False:
            parts.append("[%d] = false" % inv)
        elif v is not None:
            parts.append("[%d] = { id = %d }" % (inv, v))
    return "{ " + ", ".join(parts) + " }"


def add(c, name, d):
    return c.eval("return ns.Wardrobe:Add(..., %s).id" % slots(d), name)


def status(c, oid):
    return c.eval_py("local s, n = ns.Wardrobe:Status(ns.Wardrobe:Get(...)); local out = {} "
                     "for inv, x in pairs(s) do out[tostring(inv)] = x.st end; return { s = out, n = n }", oid)


def wear(w, c, oid, secs=4):
    res = c.eval("return ns.Wardrobe:Wear(...)", oid)
    settle(w, secs)
    return res


@r.case
def save_what_i_wear():
    w, c = solo()
    c.eval("local W = ns.Wardrobe; local real = GetInventoryItemLink; GetInventoryItemLink = function(u, s) "
           "if s == 1 then return '|cffa335ee|Hitem:29073:3003:32409:24027:0:0:0:0:70|h[Justicar Crown]|h|r' end "
           "return real(u, s) end; __o = W:SaveWorn('Ret'); GetInventoryItemLink = real")
    o = c.eval_py("local o = __o; local n = 0; for _ in pairs(o.slots) do n = n + 1 end "
                  "return { n = n, head = o.slots[1].key, oh = o.slots[17], shirt = o.slots[4] == nil, "
                  "tabard = o.slots[19] == nil, name = o.name, mh = o.slots[16].id }")
    assert o["n"] == 17, o
    assert o["head"] == "29073:3003:32409:24027:0:0:0", o
    assert o["oh"] is False and o["shirt"] and o["tabard"], o
    assert o["mh"] == LIONHEART and o["name"] == "Ret"
    # per character, in the saved data; worn = "Wearing"
    assert c.eval("return #ns.db.wardrobe[ns.Util.PlayerKey()].outfits") == 1
    assert c.eval("return ns.Wardrobe:IsWorn(__o)") is True
    st = status(c, c.eval("return __o.id"))
    assert st["n"]["worn"] == 17 and st["n"]["swap"] == 0, st
    assert_no_lua_errors(w)


@r.case
def status_bags_bank_missing_keep():
    w, c = solo(bags={(0, 1): JUSTICAR_FACE, (0, 2): GILDED_CLOAK})
    c.set_bank({(-1, 1): KINGS_DEFENDER})
    settle(w, 0.5)
    c.close_bank()
    settle(w, 0.5)
    oid = add(c, "Prot", {1: JUSTICAR_FACE, 15: GILDED_CLOAK, 16: KINGS_DEFENDER, 5: JUSTICAR_CHEST, 2: P1[2]})
    st = status(c, oid)
    s = st["s"]
    assert s["1"] == "swap" and s["15"] == "swap", s          # in the bags
    assert s["16"] == "bank", s                                # seen in the bank before it closed
    assert s["5"] == "missing", s                              # nowhere
    assert s["2"] == "worn", s
    assert s["3"] == "keep" and st["n"]["keep"] == 12, st
    # the list's pill: missing beats bank
    assert c.eval("local o = ns.Wardrobe:Get(...); local _, n = ns.Wardrobe:Status(o); return n.missing, n.bank",
                  oid) == (1, 1)


@r.case
def wear_swaps_only_what_differs_and_keeps_keep_current():
    w, c = solo(bags={(0, 1): JUSTICAR_FACE, (0, 2): GILDED_CLOAK, (0, 3): JUSTICAR_CHEST})
    # head + cloak from the bags; chest kept current (nil) even though a chest is in the bags
    d = {inv: v for inv, v in P1.items()}
    d[1], d[15] = JUSTICAR_FACE, GILDED_CLOAK
    d[5] = None
    oid = add(c, "Mixed", d)
    assert wear(w, c, oid) in ("done", "retry")
    mv = moves(c)
    assert sorted(mv) == sorted(["0:1>i1", "0:2>i15"]), mv
    inv = c.eval_py("return { __MOCK.inv[1], __MOCK.inv[15], __MOCK.inv[5] }")
    assert inv == [JUSTICAR_FACE, GILDED_CLOAK, P1[5]], inv
    # the old pieces went to the bags the new ones came from
    assert c.eval_py("return { __MOCK.bags[0].slots[1].id, __MOCK.bags[0].slots[2].id }") == [P1[1], P1[15]]
    assert c.eval("return ns.Wardrobe:IsWorn(ns.Wardrobe:Get(...))", oid) is True
    assert not any("Mixed" in x for x in printed(c)), printed(c)      # (a swap that worked says nothing)
    # wearing it again: nothing to do
    c.eval("__moves = {}")
    wear(w, c, oid)
    assert moves(c) == []
    assert_no_lua_errors(w)


@r.case
def in_combat_the_swap_waits():
    w, c = solo(bags={(0, 1): JUSTICAR_FACE})
    d = dict(P1)
    d[1] = JUSTICAR_FACE
    oid = add(c, "Head", d)
    c.set_combat(True)
    assert wear(w, c, oid, 2) == "queued"
    assert moves(c) == []
    assert any("Head: armor goes on after combat" in x for x in printed(c)), printed(c)
    c.set_combat(False)
    settle(w, 3)
    assert moves(c) == ["0:1>i1"], moves(c)
    assert c.eval("return ns.Wardrobe.queued") is None


@r.case
def two_hander_and_shield_order():
    # one-hander + shield -> a two-hander: the off hand goes to the bags first, then the main hand
    gear = dict(P1)
    gear[16], gear[17] = KINGS_DEFENDER, ALDORI_SHIELD
    w, c = solo(gear=gear, bags={(0, 1): LIONHEART})
    assert c.eval("return ns.Wardrobe.IsTwoHand(...)", LIONHEART) is True
    d = dict(P1)
    d[17] = ALDORI_SHIELD          # (asked for, but a two-hander leaves no room for it)
    oid = add(c, "2H", d)
    wear(w, c, oid)
    mv = moves(c)
    assert mv[0].startswith("i17>"), mv
    assert c.eval_py("return { __MOCK.inv[16] or 0, __MOCK.inv[17] or 0 }") == [LIONHEART, 0]
    # ... and back: main hand first, then the shield
    c.eval("__moves = {}")
    back = dict(P1)
    back[16], back[17] = KINGS_DEFENDER, ALDORI_SHIELD
    oid2 = add(c, "1H", back)
    wear(w, c, oid2)
    mv = moves(c)
    assert mv[0].endswith(">i16") and mv[1].endswith(">i17"), mv
    assert c.eval_py("return { __MOCK.inv[16], __MOCK.inv[17] }") == [KINGS_DEFENDER, ALDORI_SHIELD]
    assert_no_lua_errors(w)


@r.case
def bank_pieces_come_out_while_it_is_open():
    w, c = solo()
    c.set_bank({(-1, 3): JUSTICAR_FACE})
    settle(w, 0.5)
    d = dict(P1)
    d[1] = JUSTICAR_FACE
    oid = add(c, "Bank", d)
    assert status(c, oid)["s"]["1"] == "bank"
    wear(w, c, oid)
    mv = moves(c)
    assert mv[0].startswith("-1:3>0:"), mv               # out of the bank into a free bag slot
    assert mv[1].endswith(">i1"), mv
    assert c.eval("return __MOCK.inv[1]") == JUSTICAR_FACE


@r.case
def rules_fire_and_go_back():
    w, c = solo(bags={(0, 1): JUSTICAR_FACE, (0, 2): ALDORI_SHIELD, (0, 3): KINGS_DEFENDER, (0, 4): POLE})
    W = "ns.Wardrobe"
    prot = add(c, "Prot", {1: JUSTICAR_FACE})
    c.eval(W + ":SetRule(..., 'spec', 'Protection')", prot)
    # one outfit per rule value: a second Protection outfit takes it over
    other = add(c, "Prot 2", {2: P1[2]})
    c.eval(W + ":SetRule(..., 'spec', 'Protection')", other)
    assert c.eval("return " + W + ":Get(...).rules.spec", prot) is None
    c.eval(W + ":SetRule(..., 'spec', nil); " + W + ":SetRule(select(2, ...), 'spec', 'Protection')", other, prot)
    # spec: the first look is quiet, a change wears the outfit
    c.eval("ns.BiS.DetectSpec = function() return __spec end; __spec = 'Retribution'; " + W + ":CheckSpec(true)")
    c.eval("__spec = 'Protection'; " + W + ":CheckSpec()")
    settle(w, 3)
    assert c.eval("return __MOCK.inv[1]") == JUSTICAR_FACE, moves(c)
    c.eval(W + ":SetRule(..., 'spec', nil)", prot)

    # boss: target it -> on; the kill -> back to what was worn
    c.eval("__moves = {}")
    boss = add(c, "Boss", {16: KINGS_DEFENDER, 17: ALDORI_SHIELD})
    c.eval(W + ":SetRule(..., 'boss', { kind = 'boss', name = 'Hydross the Unstable' })", boss)
    c.eval("local real = UnitName; UnitName = function(u) if u == 'target' then return 'Hydross the Unstable' end "
           "return real(u) end; " + W + ":CheckTarget(); UnitName = real")
    settle(w, 3)
    assert c.eval_py("return { __MOCK.inv[16], __MOCK.inv[17] }") == [KINGS_DEFENDER, ALDORI_SHIELD], moves(c)
    assert c.eval("return " + W + ".active.boss ~= nil") is True
    c.eval(W + ":OnEncounterEnd(1)")
    settle(w, 3)
    assert c.eval_py("return { __MOCK.inv[16], __MOCK.inv[17] or 0 }") == [LIONHEART, 0], moves(c)
    c.eval(W + ":SetRule(..., 'boss', nil)", boss)

    # mounted: on while riding, back on landing
    mount = add(c, "Ride", {2: None, 1: JUSTICAR_FACE})
    c.eval(W + ":SetRule(..., 'mount', true)", mount)
    head = c.eval("return __MOCK.inv[1]")
    c.eval("__MOCK.mounted = true; " + W + ":CheckMount()")
    settle(w, 3)
    assert c.eval("return __MOCK.inv[1]") == JUSTICAR_FACE
    c.eval("__MOCK.mounted = false; " + W + ":CheckMount()")
    settle(w, 3)
    assert c.eval("return __MOCK.inv[1]") == head
    c.eval(W + ":SetRule(..., 'mount', nil)", mount)

    # fishing pole: putting it on wears the outfit (a hat), taking it off goes back
    fish = add(c, "Fish", {1: JUSTICAR_FACE})
    c.eval(W + ":SetRule(..., 'pole', true)", fish)
    head = c.eval("return __MOCK.inv[1]")
    pole_at = c.eval_py("for s, x in pairs(__MOCK.bags[0].slots) do if x.id == ... then return s end end", POLE)
    c.eval("ns.Wardrobe.Move({ bag = 0, slot = ... }, { inv = 16 })", pole_at)
    settle(w, 3)
    assert c.eval("return __MOCK.inv[1]") == JUSTICAR_FACE, moves(c)
    assert c.eval("return " + W + ".active.pole ~= nil") is True
    c.eval("ns.Wardrobe.Move({ bag = 0, slot = ... }, { inv = 16 })", pole_at)
    settle(w, 3)
    assert c.eval("return __MOCK.inv[1]") == head, moves(c)
    assert c.eval("return __MOCK.inv[16]") == LIONHEART      # (the weapon put back on stays)
    assert_no_lua_errors(w)


PROT = {1: 29068, 3: 29070, 15: 28660, 5: 29066, 9: 29252, 10: 29067, 6: 30034, 7: 29069, 8: 33523,
        12: 29279, 13: 28528, 14: 28830, 16: KINGS_DEFENDER, 17: ALDORI_SHIELD, 18: 29388}


@r.case
def full_swap_issues_every_move_in_one_frame():
    bags = {(0, i + 1): v for i, v in enumerate(x for k, x in sorted(PROT.items()) if k != 14)}
    bags[(1, 1)] = 27484                       # (a spare, never asked for)
    w, c = solo(bags=bags)
    c.eval("__MOCK.bags[1].size = 16")
    oid = add(c, "Prot", PROT)
    st = status(c, oid)
    assert st["n"]["swap"] == 14 and st["n"]["worn"] == 1, st     # (the second trinket is already worn)
    # Wear and look before any time passes: every move is out in the same frame, but the off hand: the game still
    # has the two-hander on, so the shield goes on once it is off (a moment later; both at once = internal bag error)
    res = c.eval("local r = ns.Wardrobe:Wear(...); return r, #__moves", oid)
    assert res[1] == 13 and res[0] == "retry", res
    assert not any(m.endswith(">i17") for m in moves(c)), moves(c)
    settle(w, 1)
    assert len(moves(c)) == 14 and moves(c)[-1].endswith(">i17"), moves(c)
    assert c.eval("return ns.Wardrobe:IsWorn(ns.Wardrobe:Get(...))", oid) is True
    mv = moves(c)
    assert mv.index("i17>0:16") < mv.index("0:13>i16") if "i17>0:16" in mv else True, mv
    assert_no_lua_errors(w)


@r.case
def in_combat_weapons_now_armour_after():
    w, c = solo(bags={(0, 1): KINGS_DEFENDER, (0, 2): ALDORI_SHIELD, (0, 3): JUSTICAR_FACE})
    d = dict(P1)
    d[16], d[17], d[1] = KINGS_DEFENDER, ALDORI_SHIELD, JUSTICAR_FACE
    oid = add(c, "Tank", d)
    c.set_combat(True)
    assert c.eval("return ns.Wardrobe:Wear(...)", oid) == "retry"      # (weapons out now, checked a moment later)
    assert moves(c) == ["0:1>i16"], moves(c)               # (the two-hander first; the shield once it is off)
    settle(w, 1)
    assert sorted(moves(c)) == sorted(["0:1>i16", "0:2>i17"]), moves(c)
    assert c.eval("return ns.Wardrobe.queued ~= nil") is True
    assert any("Tank: armor goes on after combat" in x for x in printed(c)), printed(c)
    assert c.eval("return __MOCK.inv[1]") == P1[1]
    c.set_combat(False)
    settle(w, 2)
    assert moves(c)[-1] == "0:3>i1", moves(c)
    assert c.eval("return ns.Wardrobe:IsWorn(ns.Wardrobe:Get(...))", oid) is True


@r.case
def two_rings_trade_places_directly():
    # a second copy of the ring in the bags is never used: the worn ones swap slots in one move
    w, c = solo(bags={(0, 1): 28757})
    d = dict(P1)
    d[11], d[12] = P1[12], P1[11]
    oid = add(c, "Rings", d)
    wear(w, c, oid)
    assert moves(c) in (["i12>i11"], ["i11>i12"]), moves(c)
    assert c.eval_py("return { __MOCK.inv[11], __MOCK.inv[12] }") == [P1[12], P1[11]]


@r.case
def full_bags_are_reported():
    gear = dict(P1)
    gear[16], gear[17] = KINGS_DEFENDER, ALDORI_SHIELD
    bags = {(0, i): 2589 for i in range(1, 17)}          # linen cloth everywhere
    bags[(0, 16)] = LIONHEART
    w, c = solo(gear=gear, bags=bags)
    oid = add(c, "2H", P1)                                 # a two-hander: the shield needs a free bag slot
    empty = add(c, "No shield", {17: False})
    wear(w, c, oid)
    assert moves(c) == [], moves(c)
    assert any("2H: Main hand not swapped (bags full)" in x for x in printed(c)), printed(c)
    wear(w, c, empty)
    assert moves(c) == [] and c.eval("return __MOCK.inv[17]") == ALDORI_SHIELD
    assert_no_lua_errors(w)


# the client's way: the moves land a moment later, the items locked until then
DELAYED = """
  local M = __MOCK
  local real = ns.Wardrobe.Move
  __locks = {}
  IsInventoryItemLocked = function(inv) return __locks[inv] or false end
  ns.Wardrobe.Move = function(src, dst)
    for _, l in ipairs({ src, dst }) do if l.inv then __locks[l.inv] = true end end
    C_Timer.After(0.05, function()
      real(src, dst)
      for _, l in ipairs({ src, dst }) do if l.inv then __locks[l.inv] = nil end end
    end)
  end
"""


@r.case
def a_swap_that_works_says_nothing_and_the_ring_follows():
    bags = {(0, i + 1): v for i, v in enumerate(x for k, x in sorted(PROT.items()) if k != 14)}
    w, c = solo(bags=bags)
    c.eval(DELAYED)
    ret = c.eval("return ns.Wardrobe:SaveWorn('Ret').id")
    holy = add(c, "Holy", PROT)
    c.eval("ns.Wardrobe:SetBar(true)")
    settle(w, 0.5)
    tone = "return ns.WardrobeUI.bar.cells[...].face.st.tone"
    assert c.eval(tone, 1) == "on" and c.eval(tone, 2) is None
    before = len(printed(c))
    c.eval("ns.WardrobeUI.bar.cells[2]:Click()")             # one click
    settle(w, 0.1)
    assert c.eval(tone, 2) == "on", "the ring moves on the click"
    settle(w, 2)
    assert c.eval("return ns.Wardrobe:IsWorn(ns.Wardrobe:Get(...))", holy) is True
    assert c.eval(tone, 2) == "on" and c.eval(tone, 1) is None
    assert printed(c)[before:] == [], printed(c)[before:]
    assert len(moves(c)) == 14, moves(c)
    # no tooltip on the bar (the user asked for none)
    c.eval("GameTooltip:Hide(); local b = ns.WardrobeUI.bar.cells[1]; b:GetScript('OnEnter')(b)")
    assert c.eval("return GameTooltip:IsShown()") is False
    c.eval("local b = ns.WardrobeUI.bar.cells[1]; b:GetScript('OnLeave')(b)")
    # and back with one click
    c.eval("ns.WardrobeUI.bar.cells[1]:Click()")
    settle(w, 2)
    assert c.eval("return ns.Wardrobe:IsWorn(ns.Wardrobe:Get(...))", ret) is True
    assert c.eval(tone, 1) == "on" and c.eval(tone, 2) is None
    assert printed(c)[before:] == [], printed(c)[before:]
    assert_no_lua_errors(w)


@r.case
def demo_mode_moves_and_saves_nothing():
    w, c = solo()
    c.slash("/dz demo on")
    settle(w, 1)
    names = c.eval_py("local t = {} for i, o in ipairs(ns.Wardrobe:List()) do t[i] = o.id end return t")
    assert names == ["ret", "prot", "hydross", "fish"], names
    st = status(c, "prot")
    assert st["s"]["16"] == "bank" and st["n"]["keep"] == 1, st
    assert c.eval("return ns.Wardrobe:Wear('prot')") == "demo"
    settle(w, 2)
    assert moves(c) == []
    assert c.eval("return ns.Wardrobe:Wearing().id") == "prot"
    c.eval("ns.Wardrobe:SaveWorn('x'); ns.Wardrobe:SetRule('prot', 'mount', true)")
    assert c.eval("return ns.db.wardrobe == nil or ns.db.wardrobe[ns.Util.PlayerKey()] == nil") is True
    # the rules never fire in demo
    c.eval("__MOCK.mounted = true; ns.Wardrobe:CheckMount()")
    settle(w, 2)
    assert moves(c) == []
    c.eval("ns.MainFrame:Open('wardrobe'); ns.WardrobeUI:Select('prot')")
    settle(w, 0.5)
    c.slash("/dz demo off")
    settle(w, 1)
    assert c.eval("return #ns.Wardrobe:List()") == 0
    assert_no_lua_errors(w)


@r.case
def page_builds_and_renders():
    w, c = solo(bags={(0, 1): JUSTICAR_FACE})
    c.slash("/dz wardrobe")
    settle(w, 0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "wardrobe"
    assert c.eval("return ns.WardrobeUI.view.layout:IsEmptyShown()") is True
    c.eval("ns.Wardrobe:SaveWorn('Ret')")
    d = dict(P1)
    d[1] = JUSTICAR_FACE
    oid = add(c, "Head", d)
    settle(w, 0.5)
    assert c.eval("return ns.WardrobeUI.view.layout:IsEmptyShown()") is False
    c.eval("ns.WardrobeUI:Select(...); ns.WardrobeUI:SetTab('outfit')", oid)
    settle(w, 0.3)
    assert c.eval("return ns.WardrobeUI.view.body.sum.l1:GetText()").find("1 slot swaps") >= 0
    assert c.eval("return ns.WardrobeUI.view.rows[1].stat:IsShown()") is True       # Wearing
    c.eval("ns.WardrobeUI:OpenPicker(ns.WardrobeUI.view.body.tiles[1])")
    n = c.eval("local p = ns.WardrobeUI.view.picker; local n = 0 for _, r in ipairs(p.rows) do "
               "if r:IsShown() then n = n + 1 end end return n")
    assert n == 3, n                                           # worn, the bag's helm, Keep current
    c.eval("ns.WardrobeUI.view.picker.rows[3]:Click()")      # Keep current
    assert c.eval("return ns.Wardrobe:Get(...).slots[1] == nil", oid) is True
    c.eval("ns.WardrobeUI:OpenIcons(); ns.WardrobeUI.view.icons.cells[1]:Click()")
    c.eval("ns.WardrobeUI:SetTab('auto'); ns.WardrobeUI:ToggleRule('pole', true); ns.WardrobeUI:ToggleRule('spec', true)")
    settle(w, 0.3)
    assert c.eval("return ns.Wardrobe:Get(...).rules.pole", oid) is True
    assert c.eval("return ns.WardrobeUI.view.auto.rules[3].on") is True
    # the bar: off by default, on with the switch, a click wears
    assert c.eval("return DisasterZoneWardrobeBar == nil or not DisasterZoneWardrobeBar:IsShown()") is True
    c.eval("ns.Wardrobe:SetBar(true)")
    settle(w, 0.5)
    assert c.eval("return DisasterZoneWardrobeBar:IsShown()") is True
    assert c.eval("return ns.Layout:Item('wardrobe') ~= nil") is True
    c.eval("ns.WardrobeUI.bar.cells[1]:Click()")
    settle(w, 2)
    # the outfit menu opens on a row's right-click; Delete asks first (ns.Popup) and then deletes
    c.eval("ns.WardrobeUI:Select(...); ns.WardrobeUI:OutfitMenu(ns.WardrobeUI.view.rows[2])", oid)
    c.eval("ns.UI:CloseMenus()")
    n = c.eval("return #ns.Wardrobe:List()")
    c.eval("ns.Wardrobe:Delete(...)", oid)
    assert c.eval("return #ns.Wardrobe:List()") == n - 1
    assert_no_lua_errors(w)


if __name__ == "__main__":
    r.run()
