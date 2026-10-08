"""Shared helpers for the boot-ui scenario tests (real DisasterZone addon + tools/harness.py).

Every test file in this folder is standalone:  luaenv\\Scripts\\python.exe tests\\boot-ui\\test_x.py
Each file registers cases with @case, then calls run_all(), which runs every case (even after a failure),
prints PASS/FAIL per case and exits non-zero if any case failed.
"""
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.dirname(os.path.dirname(HERE))
TOOLS = os.path.join(SCRATCH, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
TESTS = os.path.join(SCRATCH, "tests")
if TESTS not in sys.path:
    sys.path.insert(0, TESTS)

from harness import World, Client, ExtraMember, LuaErrorsFound, LuaEvalError, in_shard  # noqa: E402,F401
from cdl_council import (seed_guild_council, gm_pick, raid_pick, council_of, key,  # noqa: E402,F401
                         GUILD_INFO_SPY, guild_info_calls)

try:  # the Windows console is cp1252; addon strings contain UTF-8 glyphs
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_CASES = []


def toc_version():
    """'## Version' of the addon under test (the release tool bumps and restores it; tests must not pin it)."""
    import harness
    for line in open(os.path.join(harness.ADDON_DIR, "DisasterZone.toc"), encoding="utf-8-sig"):
        if line.startswith("## Version:"):
            return line.split(":", 1)[1].strip()
    raise AssertionError("DisasterZone.toc has no ## Version")


def case(fn):
    """Register a test case (a function without arguments)."""
    _CASES.append(fn)
    return fn


def run_all(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    flt = None
    if "-k" in argv:
        flt = argv[argv.index("-k") + 1]
    failed, passed = [], 0
    t_all = time.time()
    picked = [fn for fn in _CASES if not flt or flt in fn.__name__]
    for fn in [fn for i, fn in enumerate(picked) if in_shard(i)]:
        name = fn.__name__
        t0 = time.time()
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - report every failure, keep going
            failed.append(name)
            print("FAIL %s (%.2fs)" % (name, time.time() - t0))
            msg = "".join(traceback.format_exception(type(e), e, e.__traceback__))
            print("    " + msg.replace("\n", "\n    ").rstrip())
        else:
            passed += 1
            print("PASS %s (%.2fs)" % (name, time.time() - t0))
    total = passed + len(failed)
    print("-- %s: %d case(s), %d passed, %d failed (%.1fs)" % (
        os.path.basename(sys.argv[0]), total, passed, len(failed), time.time() - t_all))
    if failed:
        print("-- failed: " + ", ".join(failed))
    sys.exit(1 if failed else 0)


# ------------------------------------------------------------------------------------------------------------------
# world helpers
# ------------------------------------------------------------------------------------------------------------------
def solo(name="Alice", class_file="PALADIN", guild_rank=3, guild="Casual Disaster", tick=2.0, talents=(41, 20, 0),
         council=None, phase=1, members=(), load=True, **kw):
    """One-client world. members: [(name, class, rank)] extra (offline) guild members.
    council: names on the Guild Master's guild council list (Addendum E), stored on the client as if received
    earlier (cdl_council.seed_guild_council); phase: the guild phase of that list. council=None: no list."""
    w = World()
    if council is not None:
        seed_guild_council(w, council, phase=phase, guild=guild or "Casual Disaster")
    for m in members:
        n, cl, rank = m[0], m[1], m[2]
        w.add_offline_member(n, cl, rank)
    c = Client(w, name, class_file=class_file, guild_rank=guild_rank, guild=guild, talents=talents, **kw)
    if load:
        c.load_addon()
        w.tick(tick)
    return w, c


def printed_since(c, n0):
    """Chat-frame lines added since index n0 (strings)."""
    return [str(x) for x in c.chat_frame[n0:]]


def chat_contains(c, n0, needle):
    return any(needle in line for line in printed_since(c, n0))


def lua_bool(c, code, *args):
    return bool(c.eval(code, *args))


def visible_texts(c, needle):
    """Visible regions whose text contains needle."""
    return c.find_text(needle, True, True)


def text_of(c, region):
    return c.eval("local r = ...; return r:GetText()", region)


def menu_texts(menu, out=None, depth=0):
    """Flatten an exported menu into [(depth, kind, text, enabled)]."""
    out = [] if out is None else out
    if not menu:
        return out
    for ch in menu.get("children") or []:
        out.append((depth, ch.get("kind"), ch.get("text"), ch.get("enabled")))
        menu_texts(ch, out, depth + 1)
    return out


def menu_find(menu, text):
    """Depth-first search for an entry with exactly this text; returns the exported entry or None."""
    if not menu:
        return None
    for ch in menu.get("children") or []:
        if ch.get("text") == text:
            return ch
        r = menu_find(ch, text)
        if r:
            return r
    return None


def strip_codes(s):
    """Remove |cffxxxxxx, |r, |T...|t escapes for text asserts."""
    import re
    if s is None:
        return None
    s = re.sub(r"\|c[0-9a-fA-F]{8}", "", s)
    s = s.replace("|r", "")
    s = re.sub(r"\|T[^|]*\|t", "", s)
    return s


def menu_pick(c, label):
    """Invoke the entry of c's last menu whose text, without colour / icon escapes, is `label` (entries such as
    My BiS's More menu start with an icon: "|T...|t  Import")."""
    entries = [e[2] for e in menu_texts(c.last_menu()) if e[2]]
    for text in entries:
        if strip_codes(text).strip() == label:
            return c.menu_select(text)
    raise AssertionError("no menu entry %r in %r" % (label, [strip_codes(t).strip() for t in entries]))


def menu_labels(c):
    """{plain text: enabled} of c's last menu (colour / icon escapes removed)."""
    return {strip_codes(e[2]).strip(): e[3] for e in menu_texts(c.last_menu()) if e[2]}


def no_errors(w, allow=()):
    """assert_no_errors, optionally ignoring errors that contain one of the `allow` substrings (documented)."""
    errs = [e for e in w.errors() if not any(a in e for a in allow)]
    if errs:
        raise LuaErrorsFound("%d Lua error(s):\n\n%s" % (len(errs), "\n\n".join(errs)))


def addon_msgs(w, since=0):
    return w.addon_log[since:]


def db_py(c, path="DisasterZoneDB"):
    return c.eval_py("return " + path)


# ------------------------------------------------------------------------------------------------------------------
# Lua-side helpers (installed as globals T_* in a client runtime; re-install after relog)
# ------------------------------------------------------------------------------------------------------------------
LUA_HELPERS = r"""
local OBJ = __MOCK.OBJ
function T_desc(root, pred)
  local out = {}
  local function walk(f)
    local st = OBJ[f]
    if not st then return end
    for _, ch in ipairs(st.children) do
      local cs = OBJ[ch]
      if cs and pred(ch, cs) then out[#out + 1] = ch end
      walk(ch)
    end
  end
  walk(root)
  return out
end
function T_first(root, pred) return T_desc(root, pred)[1] end
function T_template(root, tpl) return T_desc(root, function(f, st) return st.template == tpl end) end
function T_search(root) return T_first(root, function(f) return rawget(f, "cdlSearch") == true end) end  -- UI:CreateSearchBox
function T_button(root, label)  -- Button (not CheckButton) whose own text is `label`
  return T_first(root, function(f, st)
    return (st.kind == "Button") and f.GetText and f:GetText() == label
  end)
end
function T_textregion(root, needle)  -- FontString containing needle (plain)
  return T_first(root, function(f, st)
    return st.kind == "FontString" and type(st.text) == "string" and string.find(st.text, needle, 1, true) ~= nil
  end)
end
function T_dropdown(root, defaultText) -- a dropdown by its default text (flat: defaultText, or a menu button's label)
  return T_first(root, function(f, st)
    if st.default_text == defaultText then return true end
    if rawget(f, "OpenMenu") == nil then return false end
    local d = rawget(f, "defaultText")
    if d ~= nil then return d == defaultText end
    return f.GetText and f:GetText() == defaultText
  end)
end
function T_is_dropdown(f, st) return st.menu_gen ~= nil or rawget(f, "OpenMenu") ~= nil end
function T_dropdown_list(root) return T_desc(root, T_is_dropdown) end
function T_menu(f)               -- a dropdown's menu (built now): a WowStyle1 one, or a flat one (opened)
  if OBJ[f].menu_gen ~= nil then f:GenerateMenu(); return f:GetMenuDescription() end
  f:OpenMenu()
  return __MOCK.last_menu
end
function T_multi_dropdown(root) return T_first(root, function(f) return rawget(f, "multi") == true end) end
function T_checkbox(root, label)  -- ns.UI:CreateCheckbox result by its label
  return T_first(root, function(f, st)
    local l = rawget(f, "label")
    return st.kind == "CheckButton" and l and l.GetText and l:GetText() == label
  end)
end
function T_visible(f) return __MOCK.is_visible(f) end
function T_shown(f) return OBJ[f] and OBJ[f].shown end
function T_state(f) return OBJ[f] end
function T_box(root) return T_first(root, function(f, st) return st.template == "WowScrollBoxList" and __MOCK.is_visible(f) end) end
function T_data(box) local dp = box and box:GetDataProvider(); return dp and dp.collection or {} end
function T_rows(box) return box and box:GetFrames() or {} end
function T_script(f, name, ...) __MOCK.call_script(f, name, ...) end
-- My BiS
function T_mybis() return ns.MainFrame:GetPanel("mybis") end
function T_doll(root) return T_first(root or T_mybis(), function(f) return rawget(f, "tiles") ~= nil end) end
function T_tile(sid, root) return rawget(T_doll(root), "tiles")[sid] end
function T_card() return T_first(T_mybis(), function(f) return rawget(f, "model") ~= nil and rawget(f, "lockBanner") ~= nil end) end
function T_links() return __MOCK.inserted_links end
function T_clear_links() for i = #__MOCK.inserted_links, 1, -1 do __MOCK.inserted_links[i] = nil end end
function T_ttlines(tt)
  tt = tt or GameTooltip
  local st = OBJ[tt]
  local out = {}
  for i = 1, st.nlines do
    local l = st.lines[i]
    out[i] = { l.left and OBJ[l.left].text or "", l.right and OBJ[l.right].text or "" }
  end
  return out
end
"""


def install_helpers(c):
    c.eval(LUA_HELPERS)
    return c


def tt_lines(c, tt="GameTooltip"):
    """[(left, right)] of a tooltip (strings, '' when empty)."""
    rows = c.eval_py("return T_ttlines(%s)" % tt) or []
    return [(r[0] if len(r) > 0 else "", r[1] if len(r) > 1 else "") for r in rows]


def plain(v):
    """Deep copy of an eval_py result with harness EmptyTable values turned into {} (comparable, mutable)."""
    if isinstance(v, dict) or type(v).__name__ == "EmptyTable":
        try:
            items = list(v.items())
        except Exception:
            items = []
        return {k: plain(x) for k, x in items}
    if isinstance(v, list):
        return [plain(x) for x in v]
    return v
