"""The notification center (Core/Notify.lua, UI/Notify.lua, UI/NotifySources.lua): sections register kinds and say
what waits for the player (sources) or what happened (posts); the bell in the nav strip counts what needs you, its
tray answers in place, the Notifications page keeps the week, pop-ups queue and wait out combat, counts roll up to the
nav tabs and the minimap button, Home's chips read the same feed, and Settings > Notifications decides what pops up.

Run: luaenv\\Scripts\\python.exe tests\\notify\\test_notify.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from _common import case, run_all, solo, no_errors, strip_codes, printed_since  # noqa: E402
import rp_common as rp  # noqa: E402

DAY = 86400

# A test kind fed from a Lua table (__T.items) on page "raids" (Raids group tab), needs you.
TEST_KIND = """
__T = __T or { items = {}, acted = 0 }
ns.Notify:RegisterKind("testKind", { section = "Tests", page = "raids", icon = 46, label = "Test things",
  desc = "Things the tests put there.", needsYou = true, popup = true, sound = true,
  open = function(it) __T.opened = it.key end,
  actions = function(it) return { { text = "Do it", primary = true, fn = function() __T.acted = __T.acted + 1;
    __T.items[it.key] = nil end } } end })
ns.Notify:RegisterSource("testKind", function()
  local out = {}
  for k, v in pairs(__T.items) do out[#out + 1] = { key = k, title = v.title, text = v.text, n = v.n, time = v.time } end
  return out
end)
"""

NEWS_KIND = """
ns.Notify:RegisterKind("testNews", { section = "Tests", label = "Test news", needsYou = false, popup = true,
  open = function() end })
"""


def setup(c, news=False):
    c.eval(TEST_KIND)
    if news:
        c.eval(NEWS_KIND)
    c.world.tick(0.5)


def put(c, key, title, n=None, text=None):
    c.eval("local k, t, n, x = ...; __T.items[k] = { title = t, n = n, text = x }; ns.Notify:Refresh('testKind')",
           key, title, n, text)
    c.world.tick(0.3)


def drop(c, key):
    c.eval("__T.items[...] = nil; ns.Notify:Refresh('testKind')", key)
    c.world.tick(0.3)


def count(c, flt=None):
    return c.eval("return ns.Notify:Count(...)", flt)


def toast(c):
    return c.eval_py("""
      local t = ns.NotifyUI:GetToast()
      if not (t and t:IsShown()) then return nil end
      local btns = {}
      for _, b in ipairs(t.btns) do if b:IsShown() then btns[#btns + 1] = b:GetText() end end
      return { title = t.title:GetText(), kicker = t.kicker:GetText(), text = t.text:GetText(), btns = btns,
               later = t.later:IsShown(), timed = t.left ~= nil }""")


def toast_button(c, text):
    return c.eval("""
      local t = ns.NotifyUI:GetToast()
      for _, b in ipairs(t.btns) do if b:IsShown() and b:GetText() == ... then return b end end""", text)


def open_window(c, key="home"):
    c.eval("ns.MainFrame:Open(...)", key)
    c.world.tick(0.5)


def bell(c):
    return c.eval_py("""
      local b = ns.NotifyUI:GetBell()
      if not b then return nil end
      return { shown = b:IsVisible(), count = b.count:IsShown() and b.count.fs:GetText() or false,
               dot = b.dot:IsShown() }""")


def nav_count(c, nav_key):
    return c.eval("""
      local tab = ns.MainFrame:GetNavTabs()[...]
      for _, ch in ipairs({ tab:GetChildren() }) do
        if ch.SetCount and ch:IsShown() then return ch.fs:GetText() end
      end
      return false""", nav_key)


def tray_rows(c):
    return c.eval_py("""
      local t = ns.NotifyUI:GetTray()
      local out = {}
      if not (t and t:IsShown()) then return out end
      for _, r in ipairs(t.list.rows or {}) do
        if r:IsShown() then
          local btns = {}
          for _, b in ipairs(r.btns) do if b:IsShown() then btns[#btns + 1] = b:GetText() end end
          out[#out + 1] = { title = r.title:GetText(), kicker = r.kicker:GetText(), fresh = r.dot:IsShown(), btns = btns }
        end
      end
      return out""") or []


def home_chip(c, prefix):
    return c.eval("""
      local prefix = ...
      for _, ch in ipairs(ns.Dashboard:GetPanel().chips) do
        if ch:IsShown() and (ch.text:GetText() or ""):find(prefix, 1, true) then return ch end
      end
      return nil""", prefix)


@case
def a_source_feeds_the_bell_the_nav_tab_and_leaves_when_handled():
    w, c = solo("Alice")
    setup(c)
    open_window(c)
    assert bell(c) == {"shown": True, "count": False, "dot": False}, bell(c)
    put(c, "a", "Something waits")
    assert count(c) == 1 and count(c, {"page": "raids"}) == 1
    assert bell(c)["count"] == "1", bell(c)
    assert nav_count(c, "grp:raids") == "1", "the count rolls up to the Raids group's tab"
    put(c, "b", "Another thing")
    assert bell(c)["count"] == "2" and nav_count(c, "grp:raids") == "2"
    drop(c, "a")
    assert bell(c)["count"] == "1", bell(c)
    done = c.eval_py("return ns.Notify:ListDone()")
    assert [d["title"] for d in done] == ["Something waits"], done
    drop(c, "b")
    assert bell(c)["count"] is False and nav_count(c, "grp:raids") is False
    no_errors(w)


@case
def a_new_item_pops_up_once_with_its_buttons_and_the_button_acts():
    w, c = solo("Alice")
    setup(c)
    n0 = len(c.sounds)
    put(c, "a", "Answer this", text="One line under it")
    t = toast(c)
    assert t and t["title"] == "Answer this" and t["btns"] == ["Do it"] and t["later"], t
    assert strip_codes(t["kicker"]).startswith("TESTS"), t
    assert not t["timed"], "a needs-you pop-up stays until answered or Later"
    assert len(c.sounds) > n0, "its kind plays a sound"
    c.click(toast_button(c, "Do it"))
    w.tick(0.5)
    assert c.eval("return __T.acted") == 1
    assert toast(c) is None and count(c) == 0
    # the same item again later is not new: no second pop-up for an id already shown
    put(c, "a", "Answer this")
    assert toast(c) is None, toast(c)
    no_errors(w)


@case
def pop_ups_queue_one_at_a_time_and_later_shows_the_next():
    w, c = solo("Alice")
    setup(c)
    put(c, "a", "First")
    put(c, "b", "Second")
    t = toast(c)
    assert t["title"] == "First", t
    c.click(c.eval("return ns.NotifyUI:GetToast().later"))
    w.tick(0.3)
    assert toast(c)["title"] == "Second", toast(c)
    assert count(c) == 2, "Later keeps both in the bell"
    no_errors(w)


@case
def pop_ups_wait_until_combat_ends():
    w, c = solo("Alice")
    setup(c)
    c.set_combat(True)
    w.tick(0.2)
    put(c, "a", "During the pull")
    assert toast(c) is None, "nothing pops in combat"
    assert count(c) == 1
    c.set_combat(False)
    w.tick(2)
    assert toast(c) and toast(c)["title"] == "During the pull", toast(c)
    no_errors(w)


@case
def a_growing_stack_is_news_again():
    w, c = solo("Alice")
    setup(c)
    put(c, "r", "Pugsy asks to join", n=1)
    c.click(c.eval("return ns.NotifyUI:GetToast().later"))
    w.tick(0.3)
    assert toast(c) is None
    put(c, "r", "Pugsy and 2 more ask to join", n=3)
    t = toast(c)
    assert t and t["title"] == "Pugsy and 2 more ask to join", t
    assert count(c) == 1, "one item, a stack of 3"
    no_errors(w)


@case
def settings_turn_a_kinds_pop_up_off_and_its_chat_line_on():
    w, c = solo("Alice")
    setup(c)
    c.eval("ns.Notify:SetWants('testKind', 'popup', false); ns.Notify:SetWants('testKind', 'chat', true)")
    n0 = len(c.chat_frame)
    put(c, "a", "Quietly here")
    assert toast(c) is None
    lines = [strip_codes(x) for x in printed_since(c, n0)]
    assert any("Quietly here" in x for x in lines), lines
    assert count(c) == 1, "the bell still has it"
    # the settings page lists the kind with its three switches
    open_window(c, "settings")
    c.eval("ns.SettingsUI:SelectSection('notify')")
    w.tick(0.3)
    texts = [strip_codes(x) for x in c.eval_py("""
      local out = {}
      local sec = ns.SettingsUI.sections.notify
      for _, r in ipairs(sec.rows) do out[#out + 1] = r.title:GetText() end
      return out""")]
    assert "Test things" in texts and "Raid answers" in texts and "Quiet in combat" in texts, texts
    no_errors(w)


@case
def seen_and_shown_marks_and_posts_survive_a_reload():
    w, c = solo("Alice")
    setup(c, news=True)
    put(c, "a", "Still waiting")
    assert toast(c)
    c.eval("ns.Notify:Post('testNews', { key = 'n1', title = 'It happened' })")
    w.tick(0.3)
    c.relog()
    w.tick(2)
    setup(c, news=True)
    put(c, "a", "Still waiting")
    w.tick(1)
    assert toast(c) is None, "no pop-up again after a reload: %r" % toast(c)
    news = c.eval_py("local out = {}; for _, it in ipairs(ns.Notify:List({ needsYou = false })) do "
                     "out[#out + 1] = it.title end; return out")
    assert "It happened" in news, news
    no_errors(w)


@case
def the_first_look_on_a_character_is_quiet():
    w, c = solo("Alice")
    c.eval("__T = { items = { old = { title = 'From before' } } }")
    c.eval("DisasterZoneDB.notify = nil; ns.Notify:Reload()")
    setup(c)
    w.tick(1)
    assert count(c) == 1, "it counts"
    assert toast(c) is None, "but the first look never pops what was already there"
    no_errors(w)


@case
def the_tray_lists_needs_you_answers_in_place_and_reads_the_news():
    w, c = solo("Alice")
    setup(c, news=True)
    c.eval("ns.Notify:SetWants('testKind', 'popup', false); ns.Notify:SetWants('testNews', 'popup', false)")
    put(c, "a", "Waits for me")
    c.eval("ns.Notify:Post('testNews', { key = 'n1', title = 'Loot for me' })")
    w.tick(0.3)
    open_window(c)
    c.click(c.eval("return ns.NotifyUI:GetBell()"))
    w.tick(0.3)
    rows = tray_rows(c)
    assert [r["title"] for r in rows] == ["Waits for me"], rows
    assert rows[0]["btns"] == ["Do it"] and rows[0]["fresh"], rows
    c.click(c.eval("return ns.NotifyUI:GetTray().segAll"))
    w.tick(0.2)
    rows = [r for r in tray_rows(c) if r["kicker"].startswith("TESTS")]
    assert [r["title"] for r in rows] == ["Waits for me", "Loot for me"], rows
    # answering on the row
    c.click(c.eval("return ns.NotifyUI:GetTray().list.rows[1].btns[1]"))
    w.tick(0.5)
    assert c.eval("return __T.acted") == 1 and count(c) == 0
    # closing the tray reads the news: the bell's dot goes
    assert c.eval("return ns.Notify:UnseenCount({ section = 'Tests' })") == 1
    c.eval("ns.NotifyUI:CloseTray()")
    w.tick(0.3)
    assert c.eval("return ns.Notify:UnseenCount()") == 0
    assert bell(c) == {"shown": True, "count": False, "dot": False}, bell(c)
    no_errors(w)


@case
def the_notifications_page_has_sections_and_the_handled_list():
    w, c = solo("Alice")
    setup(c)
    c.eval("ns.Notify:SetWants('testKind', 'popup', false)")
    put(c, "a", "One")
    put(c, "b", "Two")
    drop(c, "b")
    c.eval("ns.NotifyUI:OpenPage('needs')")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "notify"
    rail = c.eval_py("""
      local out = {}
      for _, b in ipairs(ns.NotifyUI:GetPage().items) do
        if b:IsShown() then out[#out + 1] = b.fs:GetText() .. '|' .. (b.n:GetText() or '') end
      end
      return out""")
    assert "Needs you|1" in rail and "Tests|1" in rail and "Handled|1" in rail, rail
    page_titles = c.eval_py("local out = {}; for _, r in ipairs(ns.NotifyUI:GetPage().list.rows) do "
                            "if r:IsShown() then out[#out + 1] = r.title:GetText() end end; return out")
    assert page_titles == ["One"], page_titles
    assert not c.eval("return ns.MainFrame:IsPageShown('notify')"), "no tab of its own in the strip"
    no_errors(w)


@case
def a_raid_invite_reaches_the_bell_a_pop_up_and_home_then_leaves_once_answered():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    tid = rp.team(bob, "Kara A", ["Lee", "Rita"])
    occ = rp.create(bob, i="kara", t=rp.now(bob) + DAY, tm=[tid], sz=10)
    w.tick(3)
    items = lee.eval_py("local out = {}; for _, it in ipairs(ns.Notify:List()) do out[#out + 1] = it.kind end; "
                        "return out")
    assert "raidAnswer" in items, items
    t = toast(lee)
    assert t and t["title"] == "Karazhan" and t["btns"] == ["Accept", "Tentative"], t
    open_window(lee)
    assert home_chip(lee, "Sign up: ") is not None
    assert nav_count(lee, "grp:raids") == "1"
    lee.click(toast_button(lee, "Accept"))
    w.tick(1)
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", occ)["st"] == "A"
    assert lee.eval("return ns.Notify:Count({ kind = 'raidAnswer' })") == 0
    w.tick(0.5)
    assert home_chip(lee, "Sign up: ") is None
    # the organizer, not invited, has nothing to answer
    assert bob.eval("return ns.Notify:Count({ kind = 'raidAnswer' })") == 0
    no_errors(w)


@case
def several_items_of_one_kind_make_one_home_chip():
    w, c = solo("Alice")
    c.eval("""
      __H = { items = {} }
      ns.Notify:RegisterKind("homeKind", { section = "Tests", page = "raids", label = "Home things", needsYou = true,
        popup = false, home = true, open = function(it) __H.opened = it.key end,
        chip = function(it) return { kind = "warn" } end,
        chipGroup = function(items) return { text = #items .. " home things" } end,
        openGroup = function(items) __H.group = #items end })
      ns.Notify:RegisterSource("homeKind", function()
        local out = {}
        for k, v in pairs(__H.items) do out[#out + 1] = { key = k, title = v, short = v, from = 'Bob-Test' } end
        return out
      end)""")
    w.tick(0.5)

    def put_home(key, title):
        c.eval("__H.items[...] = select(2, ...); ns.Notify:Refresh('homeKind')", key, title)
        w.tick(0.3)

    put_home("a", "Thing one")
    open_window(c)
    one = home_chip(c, "Thing one")
    assert one is not None
    c.click(one)
    assert c.eval("return __H.opened") == "a"
    put_home("b", "Thing two")
    put_home("c", "Thing three")
    c.eval("ns.Dashboard:Refresh()")
    w.tick(0.3)
    assert home_chip(c, "Thing") is None, "no chip per item once there are several"
    grp = home_chip(c, "3 home things")
    assert grp is not None
    tip = c.eval_py("return (...).tip", grp)
    assert len([l for l in tip if "Thing" in l]) == 3, tip
    c.click(grp)
    assert c.eval("return __H.group") == 3
    no_errors(w)


@case
def demo_mode_items_never_reach_saved_variables():
    w, c = solo("Alice")
    setup(c, news=True)
    c.slash("/dz demo on")
    w.tick(1)
    c.eval("ns.Notify:Post('testNews', { key = 'demo1', title = 'Aldrin did a thing', from = 'Aldrin-Thunderstrike' })")
    put(c, "d", "Demo waits")
    assert count(c) >= 1
    c.slash("/dz demo off")
    w.tick(1)
    titles = c.eval_py("local out = {}; for _, it in ipairs(ns.Notify:List()) do out[#out + 1] = it.title end; "
                       "return out")
    assert "Aldrin did a thing" not in titles, titles
    c.relog()
    w.tick(1)
    saved = c.eval_py("return DisasterZoneDB.notify") or {}
    assert "Aldrin" not in repr(saved) and "demo1" not in repr(saved), saved
    no_errors(w)


@case
def the_minimap_tooltip_lists_what_waits():
    w, c = solo("Alice")
    setup(c)
    c.eval("ns.Notify:SetWants('testKind', 'popup', false)")
    put(c, "a", "Waits on the minimap")
    lines = c.eval_py("""
      local out = {}
      local tt = { AddLine = function(_, t) out[#out + 1] = t end }
      ns.NotifyUI:AddTooltipLines(tt)
      return out""")
    assert "1 thing waits for you" in lines and "Waits on the minimap" in lines, lines
    no_errors(w)


if __name__ == "__main__":
    run_all()
