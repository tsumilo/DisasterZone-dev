"""Self-test of the uniformity guardrail (tools/uniformity.py + check.py's --uniformity flags) on fixture snippets.

Run: luaenv\\Scripts\\python.exe tools\\test_uniformity.py [-k name]   (~2 s)
"""
import io
import json
import os
import shutil
import sys
import tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import uniformity as u  # noqa: E402


def counts(src, rel="UI/Fixture.lua"):
    return u.counts_of(u.scan(src, rel))


# ---------------------------------------------------------------------------------------------------------------
def test_token_colours_counted():
    src = """
local a = { 1, 0.82, 0 }
fs:SetTextColor(1, .82, 0, 0.9)
bg:SetColorTexture(0.10, 0.10, 0.12, 0.92)
edge:SetColorTexture(0.34, 0.34, 0.38, 0.55)
sub:SetTextColor(0.62, 0.62, 0.62)
rule:SetColorTexture(1, 1, 1, 0.07)
hover:SetColorTexture(1, 1, 1, 0.05)
"""
    h = u.scan(src, "UI/Fixture.lua")["colour"]
    assert [t for _, t in h] == ["gold", "gold", "card", "edge", "grey", "hairline", "hairline"], h
    assert [ln for ln, _ in h] == [2, 3, 4, 5, 6, 7, 8], h


def test_colours_inside_longer_argument_lists():
    # a helper taking (size, r, g, b) and a gradient with two colours in one call
    src = """
b.kicker = Text(b, "GameFontNormalSmall", 10, 1, 0.82, 0)
Gradient(t, "HORIZONTAL", 1, 0.29, 0.24, 1, 1, 0.82, 0, 1)
Gradient(t, "VERTICAL", 1, 1, 1, 0.04, 1, 1, 1, 0)
"""
    h = u.scan(src, "UI/Fixture.lua")["colour"]
    assert [t for _, t in h] == ["gold", "gold", "hairline"], h


def test_near_misses_not_counted():
    src = """
local warm = { 1, 0.82, 0.25 }          -- a different gold
local light = { 0.82, 0.82, 0.82 }
local white = { 1, 1, 1, 0.1 }          -- not a hairline (alpha 0.1)
local solid = { 1, 1, 1, 1 }
local two = { 1, 0.82 }
f:SetPoint("TOPLEFT", 1, 0)
x = 21, 0.82, 0
"""
    assert counts(src)["colour"] == 0, u.scan(src, "UI/Fixture.lua")["colour"]


def test_comments_and_strings_ignored():
    src = '''
-- old: SetTextColor(1, 0.82, 0)
--[[ local function Text(p) end
     fs:SetFont(f, 12) ]]
local s = "1, 0.82, 0 and local function Gradient("
local l = [==[ kara = 1, gruul = 2, mag = 3 ]==]
print("it's", 'a "quote"') local x = 1
'''
    assert counts(src) == {"colour": 0, "helper": 0, "font": 0, "raid": 0}, u.scan(src, "UI/Fixture.lua")
    m = u.mask(src)
    assert len(m) == len(src) and m.count("\n") == src.count("\n")


def test_local_helpers():
    src = """
local function Text(parent, size) end
local function TextWidth(fs) end        -- different name
local Gradient = function(t) end
local function Now() return time() end
function M.Text(p) end                  -- not a local helper
local function grey(t) end
local Grad
"""
    h = u.scan(src, "UI/Fixture.lua")["helper"]
    assert [n for _, n in h] == ["Text", "Gradient", "Now", "grey"], h


def test_numeric_setfont_sizes():
    src = """
fs:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
fs:SetFont(select(1, fs:GetFont()), 10.5)
fs:SetFont("Fonts\\\\FRIZQT__.TTF", (11))
fs:SetFont(font, size, flags)
fs:SetFont(font, S.FONT.body)
"""
    h = u.scan(src, "UI/Fixture.lua")["font"]
    assert [ln for ln, _ in h] == [2, 3, 4], h
    assert counts(src, "UI/Style.lua")["font"] == 0  # the type scale's home


def test_raid_tables():
    src = """
local INST_SHORT = { kara = "Kara", gruul = "Gruul", mag = "Mag" }
local ART = {
  [532] = "kara",
  [565] = "gruul",
  [544] = { fdid = 1 },
}
local RAID_ICON = { Karazhan = 1, GruulsLair = 2, BlackTemple = 3 }
local ART_TOP = 0.29
local two = { kara = 1, bt = 2 }
local nested = { a = { kara = 1 }, b = { gruul = 2 }, c = { mag = 3 } }
local dungeons = { [555] = 1, [556] = 2, [557] = 3 }
"""
    h = u.scan(src, "UI/Fixture.lua")["raid"]
    assert [ln for ln, _ in h] == [2, 3, 8, 9], h
    assert counts(src, "Data/Raids.lua")["raid"] == 0  # the raid information's home


def test_baseline_only_counts_going_up():
    d = tempfile.mkdtemp(prefix="dz_uniformity_")
    try:
        path = os.path.join(d, "baseline.json")
        u.save_baseline({"UI/A.lua": {"colour": 2, "helper": 0, "font": 1, "raid": 0},
                         "UI/Clean.lua": {"colour": 0, "helper": 0, "font": 0, "raid": 0}}, path)
        base = u.load_baseline(path)
        assert base == {"UI/A.lua": {"colour": 2, "font": 1}}, base
        same = u.scan("a:SetTextColor(1, 0.82, 0)\nb:SetTextColor(1, 0.82, 0)\nc:SetFont(f, 12)\n", "UI/A.lua")
        assert u.over_baseline("UI/A.lua", same, base) == []
        fewer = u.scan("a:SetTextColor(1, 0.82, 0)\n", "UI/A.lua")
        assert u.over_baseline("UI/A.lua", fewer, base) == []
        more = u.scan("a:SetTextColor(1, 0.82, 0)\nb:SetTextColor(1, 0.82, 0)\nlocal function Text() end\n"
                      "e:SetColorTexture(0.34, 0.34, 0.38)\n", "UI/A.lua")
        up = u.over_baseline("UI/A.lua", more, base)
        assert [(k, n, b) for k, n, b, _ in up] == [("colour", 3, 2), ("helper", 1, 0)], up
        assert "UNIFORMITY colour: 3" in u.describe(*up[0]) and "baseline 2" in u.describe(*up[0])
        # merge keeps other files; a file that is clean now drops out
        u.save_baseline({"UI/B.lua": {"raid": 1}}, path, merge=True)
        assert set(u.load_baseline(path)) == {"UI/A.lua", "UI/B.lua"}
        u.save_baseline({"UI/A.lua": {}}, path, merge=True)
        assert set(u.load_baseline(path)) == {"UI/B.lua"}
        with open(path, encoding="utf-8") as fh:
            assert json.load(fh)["totals"] == {"colour": 0, "helper": 0, "font": 0, "raid": 1}
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_check_py_warns_and_strict_errors():
    import check  # needs lupa (luaenv python)
    d = tempfile.mkdtemp(prefix="dz_uniformity_")
    try:
        f = os.path.join(d, "Fixture.lua")
        with open(f, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("local addonName, ns = ...\nlocal function Text(p) return p end\n"
                     "local t = { 1, 0.82, 0 }\nreturn Text, t\n")
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, "--no-events"])
        text = out.getvalue()
        assert rc == 0, text
        assert "WARN UNIFORMITY colour: 1" in text and "WARN UNIFORMITY helper: 1" in text, text
        assert "uniformity=2" in text, text
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, "--no-events", "--uniformity-strict"])
        assert rc == 1 and "ERROR UNIFORMITY colour" in out.getvalue(), out.getvalue()
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, "--no-events", "--no-uniformity"])
        assert rc == 0 and "UNIFORMITY" not in out.getvalue(), out.getvalue()
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, "--uniformity"])
        assert rc == 0 and "TOTAL" in out.getvalue() and "UP: colour,helper" in out.getvalue(), out.getvalue()
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, "--uniformity", "--uniformity-strict"])
        assert rc == 1, out.getvalue()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    only = None
    if "-k" in sys.argv:
        only = sys.argv[sys.argv.index("-k") + 1]
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        if only and only not in name:
            continue
        try:
            fn()
            print("PASS %s" % name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(e).__name__, e))
    print("-- %s" % ("all passed" if not failed else "%d failed" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
