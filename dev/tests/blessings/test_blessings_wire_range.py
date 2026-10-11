#!/usr/bin/env python
"""Pally Power messages with a blessing or aura number out of range (a bad message, or a newer Pally Power with more
blessings) are ignored, the rest of the message still counts, and the report, the exceptions and the planner never
index a blessing that does not exist (Core/Blessings.lua; before the 1.4 fix a leader's "ASSIGN Gina 1 9" stored 9 and
the next Report raised a Lua error).

Run: luaenv\\Scripts\\python.exe tests\\blessings\\test_blessings_wire_range.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from harness import World, Client  # noqa: E402
from _common import case, run_all  # noqa: E402

COMMON = [27142, 27143, 27140, 27141, 1038, 25895, 27144, 27145, 27149, 27150, 19746, 27151, 27152, 27153]
ROW = "local n = ...; local t = {}; for ci = 1, 9 do t[ci] = ns.Blessings:GetAssign(n, ci) or 0 end; return t"


def world():
    """Caelith leads a raid with two paladins (Gina) and a Pally Power user (Holypal, a leader-made assistant who
    sends plain PLPWR lines)."""
    w = World()
    cae = Client(w, "Caelith", class_file="PALADIN", guild_rank=0, talents=(5, 41, 15))
    gina = Client(w, "Gina", class_file="PALADIN", guild_rank=2, talents=(41, 20, 0))
    pp = Client(w, "Holypal", class_file="PRIEST", guild_rank=3)
    for c in w.clients:
        c.load_addon()
    for c in (cae, gina):
        c.eval("local ids = ...; for _, id in ipairs(ids) do __MOCK.known_spells[id] = true end; ns.Blessings:ScanSelf()",
               COMMON)
    w.make_raid([cae, gina, pp], leader=pp,
                extra_members=[{"name": "Victhar", "class_file": "WARRIOR"}, {"name": "Isolde", "class_file": "PRIEST"}])
    w.tick(10)
    return w, cae, gina, pp


def plplwr(pp, text):
    pp.eval("C_ChatInfo.SendAddonMessage('PLPWR', ..., 'RAID')", text)


def report(c):
    return c.eval_py("local ok, lines = pcall(ns.Blessings.ReportLines, ns.Blessings) "
                     "return { ok = ok, lines = ok and lines or tostring(lines) }")


@case
def assign_out_of_range_is_ignored_and_report_works():
    w, cae, gina, pp = world()
    plplwr(pp, "ASSIGN Gina 1 2")
    w.tick(1)
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 1)") == 2
    # a blessing number past the Greater blessings (and one past every blessing): ignored, the old value stays
    for bad in ("ASSIGN Gina 1 7", "ASSIGN Gina 1 9", "ASSIGN Gina 2 12", "ASSIGN Gina 1 -1"):
        plplwr(pp, bad)
    w.tick(1)
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 1)") == 2
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 2)") is None
    r = report(cae)
    assert r["ok"], r
    # 0 still clears
    plplwr(pp, "ASSIGN Gina 1 0")
    w.tick(1)
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 1)") is None
    w.assert_no_errors()


@case
def massign_and_passign_keep_the_good_parts():
    w, cae, gina, pp = world()
    plplwr(pp, "MASSIGN Gina 3")
    w.tick(1)
    assert cae.eval_py(ROW, "Gina") == [3] * 9
    plplwr(pp, "MASSIGN Gina 8")         # out of range: the row stays as it was
    w.tick(1)
    assert cae.eval_py(ROW, "Gina") == [3] * 9
    assert report(cae)["ok"]
    # PASSIGN: one class per digit; the 9 for druids is ignored (keeps Kings), the others are taken
    plplwr(pp, "PASSIGN Gina@121212129")
    w.tick(1)
    assert cae.eval_py(ROW, "Gina") == [1, 2, 1, 2, 1, 2, 1, 2, 3], cae.eval_py(ROW, "Gina")
    assert report(cae)["ok"]
    w.assert_no_errors()


@case
def self_single_and_aura_out_of_range_are_dropped():
    w, cae, gina, pp = world()
    # Holypal's own record: Kings to warriors, a 9 for paladins (dropped), Wisdom to the rest
    plplwr(pp, "SELF 7280101040nn@391111111")
    plplwr(pp, "ASELF 856210404040nn10@9")
    w.tick(1)
    row = cae.eval_py(ROW, "Holypal")
    assert row == [3, 0, 1, 1, 1, 1, 1, 1, 1], row
    assert cae.eval("return ns.Blessings:GetAura('Holypal')") is None
    # single blessings and auras past the end of their lists
    plplwr(pp, "NASSIGN Gina 1 Victhar 9")
    plplwr(pp, "NASSIGN Gina 3 Isolde 1")
    plplwr(pp, "AASSIGN Gina 99")
    w.tick(1)
    assert cae.eval("return ns.Blessings:GetSingle('Gina', 1, 'Victhar')") is None
    assert cae.eval("return ns.Blessings:GetSingle('Gina', 3, 'Isolde')") == 1
    assert cae.eval("return ns.Blessings:GetAura('Gina')") is None
    r = report(cae)
    assert r["ok"], r
    assert any("Isolde" in line for line in r["lines"]), r
    w.assert_no_errors()


@case
def bad_values_saved_before_the_fix_are_not_read():
    w, cae, gina, pp = world()
    # a saved plan from before the fix may still hold a 9 (assign), a 12 (single) or a 40 (aura)
    cae.eval("""
        local t = ns.db.blessings
        t.assign.Gina = { 9, 3 }
        t.single.Gina = { [1] = { Victhar = 12 } }
        t.aura.Gina = 40
    """)
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 2)") == 3
    assert cae.eval("return ns.Blessings:GetAssign('Gina', 1)") is None
    assert cae.eval("return ns.Blessings:GetSingle('Gina', 1, 'Victhar')") is None
    assert cae.eval("return ns.Blessings:GetAura('Gina')") is None
    assert report(cae)["ok"], report(cae)
    assert cae.eval("return #ns.Blessings:Exceptions()") == 0
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
