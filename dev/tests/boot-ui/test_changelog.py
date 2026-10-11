"""The Changelog tab (UI/Changelog.lua + Data/Changelog.lua): release notes for everyone.

Covers: the tab for everyone (even without a guild), /dz changelog, the installed release first with "New · your
version", a newer release "In testing", a release's highlight cards and its sections folded to one line (open one for
its lines), Since your last visit when two or more releases are unread, "New" only for releases after the one read,
Just for me folding sections for other roles and classes away (and Show them), area chips, search across every
release, Show me (the page opens, the tour box, the back bar), the Home chip opening the What's new pop-up, From your
feedback, and the data itself (unique versions, newest first, dated, short lines, valid section fields).

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_changelog.py [-k name]
"""
from _common import case, run_all, solo, no_errors, strip_codes  # noqa: E402

WALK = """
local out = {}
local function walk(f)
  for _, r in ipairs({ f:GetRegions() }) do
    if r.GetText and r:IsVisible() and r:GetText() and r:GetText() ~= "" then out[#out + 1] = r:GetText() end
  end
  for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() then walk(ch) end end
end
"""
TEXTS_LUA = WALK + """
local p = ns.MainFrame:GetPanel(...)
if not p or not p:IsVisible() then return out end
walk(p)
return out"""
POPUP_TEXTS = WALK + """
local o = ns.ChangelogPopup
if not (o and o:IsShown()) then return out end
walk(o)
return out"""


def texts(c, key="changelog"):
    return [strip_codes(t) for t in (c.eval_py(TEXTS_LUA, key) or [])]


def popup_texts(c):
    return [strip_codes(t) for t in (c.eval_py(POPUP_TEXTS) or [])]


def selected(c):
    return c.eval("return ns.MainFrame:GetSelectedTab()")


def released(c):
    return c.eval_py("""local out = {}
      for _, e in ipairs(ns.CHANGELOG) do
        if ns.Util.CompareVersions(e.version, ns.version) <= 0 then out[#out + 1] = e.version end
      end
      return out""")


def home_chip(c, prefix):
    return c.eval("""
      local prefix = ...
      for _, ch in ipairs(ns.Dashboard:GetPanel().chips) do
        if ch:IsShown() and (ch.text:GetText() or ""):find(prefix, 1, true) then return ch end
      end
      return nil""", prefix)


def open_all(c):
    """Opens every section of the view shown (their lines show)."""
    c.eval("""local st = ns.ChangelogUI:GetState()
      for _, ne in ipairs(ns.ChangelogUI.Norm().list) do
        for _, s in ipairs(ne.sections) do st.open[s.id] = true end
      end
      ns.ChangelogUI:Render()""")


@case
def everyone_gets_the_tab_and_the_installed_release_first():
    w, c = solo("Solo", guild=None, tick=3)
    version = c.eval("return ns.version")
    c.slash("/dz changelog")
    w.tick(0.3)
    assert selected(c) == "changelog", selected(c)
    assert c.eval("return ns.ChangelogUI:GetSelected()") == version
    t = texts(c)
    assert any(x.startswith(version + " · NEW · YOUR VERSION") for x in t), t
    assert any("New · your version" in x for x in t), t
    assert "Search every version" in t and "Just for me" in t, t
    assert c.eval("return ns.db.settings.changelogSeen") == version
    newer = c.eval_py("""local out = {}
      for _, e in ipairs(ns.CHANGELOG) do
        if ns.Util.CompareVersions(e.version, ns.version) > 0 then out[#out + 1] = e.version end
      end
      return out""") or []
    if newer:
        assert any("In testing" in x for x in t), "a release newer than the installed one is marked In testing"
        c.eval("ns.ChangelogUI:Select(...)", newer[0])
        w.tick(0.1)
        assert any(("(you have " + version + ")") in x for x in texts(c)), texts(c)
    no_errors(w)


@case
def a_release_shows_highlights_then_one_line_per_section():
    w, c = solo("Rai", guild_rank=3, tick=3)
    version = c.eval("return ns.version")
    c.slash("/dz changelog")
    w.tick(0.3)
    t = texts(c)
    secs = c.eval_py("""local out = {}
      local ne = ns.ChangelogUI.Norm().by[ns.version]
      for _, s in ipairs(ne.sections) do
        local v = ns.ChangelogUI.View(s)
        if v.mine then out[#out + 1] = { title = s.title, hi = s.hi or false, lead = v.lead, n = #v.lines,
                                         last = v.lines[#v.lines].text } end
      end
      return out""")
    assert secs, version
    for s in secs:
        assert s["title"] in t, (s["title"], t)
        assert s["lead"] in t, (s["lead"], t)
        if s["n"] > 1 and s["last"] != s["lead"]:
            assert s["last"] not in t, ("folded: only the lead shows", s["last"])
    if any(s["hi"] for s in secs):
        assert "HIGHLIGHTS" in t and "EVERYTHING ELSE" in t, t
    # a click on a folded row opens its lines, another folds it again
    row = c.eval("""local p = ns.MainFrame:GetPanel('changelog')
      for _, ch in ipairs({ p.child:GetChildren() }) do
        if ch:IsShown() and ch.sec and ch.lead and not ch.isCard and #ch.sec.lines > 1 then return ch end
      end""")
    assert row is not None
    last = c.eval("local r = ...; return r.sec.lines[#r.sec.lines].text", row)
    c.click(row)
    w.tick(0.1)
    assert last in texts(c), last
    c.click(row)
    w.tick(0.1)
    assert last not in texts(c)
    no_errors(w)


@case
def every_line_of_an_old_release_reads_when_opened():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz changelog")
    w.tick(0.3)
    first = c.eval_py("return ns.CHANGELOG[#ns.CHANGELOG]")
    c.eval("ns.ChangelogUI:Select(...)", first["version"])
    open_all(c)
    w.tick(0.1)
    assert c.eval("return ns.ChangelogUI:GetSelected()") == first["version"]
    t = texts(c)
    assert first["title"] in t, t
    for section in first["sections"]:
        for line in section["lines"]:
            text = line[1] if isinstance(line, dict) else line
            if text.startswith("Fixed: "):
                text = text[7].upper() + text[8:]
            assert any(x == text or x.startswith(text + "   ") for x in t), (text, t)
    no_errors(w)


@case
def since_your_last_visit_merges_the_unread_releases():
    w, c = solo("Rai", guild_rank=3, tick=3)
    versions = released(c)
    assert len(versions) >= 3, versions
    c.eval("ns.db.settings.changelogSeen = ...", versions[2])      # two releases unread
    c.slash("/dz changelog")
    w.tick(0.3)
    assert c.eval("return ns.ChangelogUI:GetView()") == "since"
    t = texts(c)
    assert "Since your last visit" in t, t
    assert "2 new versions since you last looked" in t, t
    assert "EVERYTHING ELSE, BY AREA" in t, t
    badges = c.eval_py("""local out = {}
      local p = ns.MainFrame:GetPanel('changelog')
      for _, r in ipairs({ p.vchild:GetChildren() }) do
        if r:IsShown() and r.view and r.badge and r.version then out[r.view] = r.badge:GetText() end
      end
      return out""")
    assert "New" in strip_codes(badges[versions[0]]), badges
    assert strip_codes(badges[versions[1]]) == "New", badges
    assert "New" not in strip_codes(badges[versions[2]] or ""), badges
    assert c.eval("return ns.db.settings.changelogSeen") == versions[0]
    c.eval("ns.ChangelogUI:Select(...)", versions[1])
    w.tick(0.1)
    assert c.eval("return ns.ChangelogUI:GetSelected()") == versions[1]
    no_errors(w)


@case
def just_for_me_folds_sections_for_others_away():
    w, c = solo("Rog", class_file="ROGUE", guild_rank=5, tick=3)
    c.slash("/dz changelog")
    w.tick(0.3)
    # the release with the most sections for someone else
    v = c.eval("""local best, n = nil, 0
      for _, ne in ipairs(ns.ChangelogUI.Norm().list) do
        local k = 0
        for _, s in ipairs(ne.sections) do if s.aud and not ns.ChangelogUI.IsForMe(s.aud) then k = k + 1 end end
        if k > n then best, n = ne.version, k end
      end
      return best""")
    assert v, "some sections are tagged for a role or class"
    c.eval("ns.ChangelogUI:Select(...)", v)
    w.tick(0.1)
    others = c.eval_py("""local out = {}
      for _, s in ipairs(ns.ChangelogUI.Norm().by[...].sections) do
        if s.aud and not ns.ChangelogUI.IsForMe(s.aud) then out[#out + 1] = s.title end
      end
      return out""", v)
    t = texts(c)
    for title in others:
        assert title not in t, ("folded away", title)
    assert any("for others:" in x for x in t), t
    link = c.eval("""local p = ns.MainFrame:GetPanel('changelog')
      for _, ch in ipairs({ p.child:GetChildren() }) do
        if ch:IsShown() and ch.onClick and ch.go then return ch.go end
      end""")
    c.click(link)
    w.tick(0.1)
    assert c.eval("return ns.db.settings.changelogForMe") is False
    t = texts(c)
    for title in others:
        assert title in t, (title, t)
    no_errors(w)


@case
def area_chips_filter_the_sections():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz changelog")
    w.tick(0.3)
    chip = c.eval("""local p = ns.MainFrame:GetPanel('changelog')
      for _, ch in ipairs(p.chips) do if ch:IsShown() and ch.area then return ch end end""")
    assert chip is not None, texts(c)
    area = c.eval("local ch = ...; return ch.area", chip)
    c.click(chip)
    w.tick(0.1)
    areas = c.eval_py("""local out = {}
      local p = ns.MainFrame:GetPanel('changelog')
      for _, ch in ipairs({ p.child:GetChildren() }) do
        if ch:IsShown() and ch.sec then out[#out + 1] = ch.sec.area end
      end
      return out""")
    assert areas and all(a == area for a in areas), (area, areas)
    # the areas that don't fit sit in the More chip's menu
    more = c.eval("return ns.MainFrame:GetPanel('changelog').moreChip")
    if more is not None and c.eval("local m = ...; return m:IsShown()", more):
        last = c.eval("local m = ...; return m.over[#m.over][1]", more)
        c.eval("ns.ChangelogUI:GetState().area = ...; ns.ChangelogUI:Render()", last)
        assert c.eval("local m = ...; return m.on", more) is True
    no_errors(w)


@case
def search_finds_lines_in_every_release():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz changelog")
    w.tick(0.3)
    c.eval("ns.MainFrame:GetPanel('changelog').search:SetText('attendance')")
    w.tick(0.5)
    assert c.eval_py("return ns.ChangelogUI:GetState().query") == "attendance"
    t = texts(c)
    assert any("match attendance" in x for x in t), t
    versions = c.eval_py("""local out = {}
      for _, e in ipairs(ns.CHANGELOG) do
        for _, s in ipairs(e.sections) do
          for _, l in ipairs(s.lines) do
            if type(l) ~= 'table' and l:lower():find('attendance', 1, true) then out[e.version] = true end
          end
        end
      end
      return out""")
    shown = set(x for x in t if x in versions)
    assert len(shown) >= 2, ("results grouped by release", shown, versions)
    marked = c.eval("""local p = ns.MainFrame:GetPanel('changelog')
      local function walk(f)
        for _, r in ipairs({ f:GetRegions() }) do
          if r.GetText and r:IsVisible() and (r:GetText() or ''):lower():find('|cffffd100attendance|r', 1, true) then
            return true
          end
        end
        for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() and walk(ch) then return true end end
      end
      return walk(p.child) or false""")
    assert marked, "the word is marked gold"
    c.eval("ns.MainFrame:GetPanel('changelog').search:SetText('')")
    w.tick(0.5)
    assert c.eval_py("return ns.ChangelogUI:GetState().query") == ""
    no_errors(w)


@case
def show_me_opens_the_page_with_the_box_and_a_way_back():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz changelog")
    w.tick(0.3)
    sid = c.eval("""for _, ne in ipairs(ns.ChangelogUI.Norm().list) do
        for _, s in ipairs(ne.sections) do if s.open == 'gearsim' then return s.id end end
      end""")
    assert sid
    assert c.eval("return ns.ChangelogUI:ShowMe(...)", sid) is True
    w.tick(0.3)
    assert selected(c) == "gearsim", selected(c)
    assert c.eval("return ns.Tour:IsRunning('whatsnew')") is True
    back = c.eval("""local host = ns.MainFrame:GetFrame()
      for _, ch in ipairs({ host:GetChildren() }) do
        if ch:IsShown() and ch.back and ch.view then return ch.back end
      end""")
    assert back is not None, "the From What's new bar"
    c.eval("ns.Tour:Stop()")
    c.click(back)
    w.tick(0.3)
    assert selected(c) == "changelog"
    sid = c.eval("""for _, ne in ipairs(ns.ChangelogUI.Norm().list) do
        for _, s in ipairs(ne.sections) do if s.open == 'settings/meters' then return s.id end end
      end""")
    c.eval("ns.ChangelogUI:ShowMe(...)", sid)
    w.tick(0.3)
    assert selected(c) == "settings"
    assert c.eval("return ns.SettingsUI:GetSection()") == "meters"
    c.eval("ns.Tour:Stop()")
    no_errors(w)


@case
def home_chip_opens_the_whats_new_popup():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz")
    w.tick(0.5)
    assert selected(c) == "home"
    version = c.eval("return ns.version")
    ch = home_chip(c, "What's new in " + version)
    assert ch is not None, texts(c, "home")
    c.click(ch)
    w.tick(0.3)
    t = popup_texts(c)
    assert ("WHAT'S NEW IN " + version) in t, t
    assert "Read everything" in t and "Later" in t, t
    assert "Open by itself after an update" in t, t
    c.click(c.eval("return ns.ChangelogPopup.box.read"))
    w.tick(0.3)
    assert selected(c) == "changelog"
    assert not c.eval("return ns.ChangelogPopup:IsShown()")
    c.slash("/dz home")
    w.tick(0.5)
    assert home_chip(c, "What's new") is None, "the chip goes away once read"
    no_errors(w)


@case
def the_chip_counts_unread_versions():
    w, c = solo("Rai", guild_rank=3, tick=3)
    versions = released(c)
    c.eval("ns.db.settings.changelogSeen = ...; ns:Fire('CHANGELOG_READ')", versions[3])
    w.tick(0.5)
    c.slash("/dz")
    w.tick(0.5)
    ch = home_chip(c, "What's new · 3 versions")
    assert ch is not None, texts(c, "home")
    c.click(ch)
    w.tick(0.3)
    t = popup_texts(c)
    assert "WHAT'S NEW SINCE YOU LAST LOOKED" in t, t
    assert any(x.startswith("3 versions, ") for x in t), t
    c.click(c.eval("return ns.ChangelogPopup.box.read"))
    w.tick(0.3)
    assert c.eval("return ns.ChangelogUI:GetView()") == "since"
    no_errors(w)


@case
def from_your_feedback_lists_what_shipped():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.eval("""local e
      for _, x in ipairs(ns.CHANGELOG) do if x.version == ns.version then e = x end end
      table.insert(e.sections[1].lines, { "A line Rai asked for.", fb = { 999 }, by = { "Rai" }, k = "idea" })
      ns.ChangelogUI.ResetIndex()""")
    c.slash("/dz changelog")
    w.tick(0.3)
    assert "From your feedback" in texts(c), texts(c)
    c.eval("ns.ChangelogUI:Select('feedback')")
    w.tick(0.1)
    t = texts(c)
    assert "A line Rai asked for." in t, t
    assert any(x.startswith("1 thing you asked for") for x in t), t
    no_errors(w)


@case
def changelog_data_is_well_formed():
    w, c = solo("Rai", guild_rank=3, tick=3)
    data = c.eval_py("return ns.CHANGELOG")
    assert data and len(data) >= 7, data
    seen = set()
    areas = {"raids", "loot", "gear", "guild", "games", "class", "look", "speed", "fixes", "other"}
    tags = {"council", "officers", "leaders", "gm", "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN",
            "MAGE", "WARLOCK", "DRUID"}
    for i, e in enumerate(data):
        assert e["version"] not in seen, e["version"]
        seen.add(e["version"])
        if i > 0:
            assert c.eval("return ns.Util.CompareVersions(...)", data[i - 1]["version"], e["version"]) > 0, \
                "newest first"
        assert e.get("date") and e.get("title"), e
        assert e["sections"], e["version"]
        for s in e["sections"]:
            assert s["heading"] and s["lines"], (e["version"], s)
            assert s.get("area") is None or s["area"] in areas, (e["version"], s["heading"], s.get("area"))
            assert s.get("kind") in (None, "new", "changed", "fixed"), (e["version"], s["heading"])
            assert s.get("lead") is None or 0 < len(s["lead"]) <= 90, (e["version"], s["lead"])
            for t in (s.get("for") or "").split():
                assert t in tags, (e["version"], s["heading"], t)
            if s.get("open"):
                assert c.eval("return ns.ChangelogUI.RouteKnown(...)", s["open"]), (e["version"], s["open"])
            for line in s["lines"]:
                if isinstance(line, dict):
                    if "fb" in line or "by" in line:   # a line from the guild's feedback: { text, fb, by, mt, k }
                        assert isinstance(line.get("fb"), dict) or isinstance(line.get("fb"), list), line
                        assert line.get("k") in ("bug", "idea", "change", "love"), line
                    for t in (line.get("for") or "").split():
                        assert t in tags, (e["version"], line)
                    line = line[1]
                assert 0 < len(line) <= 90, (e["version"], line)
    assert data[-1]["version"] == "0.1.0"
    assert c.eval("local v = ...; for _, e in ipairs(ns.CHANGELOG) do if e.version == v then return true end end",
                  c.eval("return ns.version")), "the installed version has release notes"
    no_errors(w)


if __name__ == "__main__":
    run_all()
