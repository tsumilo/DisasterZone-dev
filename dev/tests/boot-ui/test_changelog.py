"""The Changelog tab (UI/Changelog.lua + Data/Changelog.lua): release notes for everyone.

Covers: the tab for everyone (even without a guild), /cdl changelog, the installed release selected first with
"New · your version", a release newer than the installed one marked "In testing", selecting another release,
"New" only for releases newer than the one read before, the Home "What's new" chip until the notes are read,
and the data itself (unique versions, newest first, dated, every release with sections and short lines).

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_changelog.py [-k name]
"""
from _common import case, run_all, solo, no_errors, strip_codes  # noqa: E402

TEXTS_LUA = """
local out = {}
local p = ns.MainFrame:GetPanel(...)
if not p or not p:IsVisible() then return out end
local function walk(f)
  for _, r in ipairs({ f:GetRegions() }) do
    if r.GetText and r:IsVisible() and r:GetText() and r:GetText() ~= "" then out[#out + 1] = r:GetText() end
  end
  for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() then walk(ch) end end
end
walk(p)
return out"""


def texts(c, key="changelog"):
    return [strip_codes(t) for t in (c.eval_py(TEXTS_LUA, key) or [])]


def selected(c):
    return c.eval("return ns.MainFrame:GetSelectedTab()")


def home_chip(c, prefix):
    return c.eval("""
      local prefix = ...
      for _, ch in ipairs(ns.Dashboard:GetPanel().chips) do
        if ch:IsShown() and (ch.text:GetText() or ""):find(prefix, 1, true) then return ch end
      end
      return nil""", prefix)


@case
def everyone_gets_the_tab_and_the_installed_release_first():
    w, c = solo("Solo", guild=None, tick=3)
    version = c.eval("return ns.version")
    c.slash("/cdl changelog")
    w.tick(0.3)
    assert selected(c) == "changelog", selected(c)
    assert c.eval("return ns.ChangelogUI:GetSelected()") == version
    t = texts(c)
    assert any(x.startswith("CDLoot " + version) for x in t), t
    assert any("New · your version" in x for x in t), t
    assert "Versions" in t and ("you have " + version) in t, t
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
def selecting_a_release_shows_its_sections():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/cdl changelog")
    w.tick(0.3)
    first = c.eval_py("return ns.CHANGELOG[#ns.CHANGELOG]")
    row = c.eval("""local v = ...
      local list = ns.MainFrame:GetPanel('changelog').list
      local found
      list.box:ForEachFrame(function(r) if r.__cdlData and r.__cdlData.entry.version == v then found = r end end)
      return found""", first["version"])
    if row is not None:      # the oldest release may sit below the fold of the list
        c.click(row)
    else:
        c.eval("ns.ChangelogUI:Select(...)", first["version"])
    w.tick(0.1)
    assert c.eval("return ns.ChangelogUI:GetSelected()") == first["version"]
    t = texts(c)
    assert any(x.startswith("CDLoot " + first["version"]) and first["title"] in x for x in t), t
    for section in first["sections"]:
        assert section["heading"] in t, (section["heading"], t)
        for line in section["lines"]:
            assert line in t, (line, t)
    no_errors(w)


@case
def new_badges_only_for_releases_after_the_one_read():
    w, c = solo("Rai", guild_rank=3, tick=3)
    versions = c.eval_py("""local out = {}
      for _, e in ipairs(ns.CHANGELOG) do
        if ns.Util.CompareVersions(e.version, ns.version) <= 0 then out[#out + 1] = e.version end
      end
      return out""")
    assert len(versions) >= 3, versions
    c.eval("ns.db.settings.changelogSeen = ...", versions[2])      # two releases unread
    c.slash("/cdl changelog")
    w.tick(0.3)
    badges = c.eval_py("""local out = {}
      local list = ns.MainFrame:GetPanel('changelog').list
      list.box:ForEachFrame(function(r) if r.__cdlData then out[r.__cdlData.entry.version] = r.badge:GetText() end end)
      return out""")
    assert "New" in strip_codes(badges[versions[0]]), badges
    assert strip_codes(badges[versions[1]]) == "New", badges
    assert "New" not in strip_codes(badges[versions[2]]), badges
    assert c.eval("return ns.db.settings.changelogSeen") == versions[0]
    no_errors(w)


@case
def home_chip_until_the_notes_are_read():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/cdl")
    w.tick(0.5)
    assert selected(c) == "home"
    version = c.eval("return ns.version")
    ch = home_chip(c, "What's new in " + version)
    assert ch is not None, texts(c, "home")
    c.click(ch)
    w.tick(0.3)
    assert selected(c) == "changelog"
    c.slash("/cdl home")
    w.tick(0.5)
    assert home_chip(c, "What's new") is None, "the chip goes away once read"
    no_errors(w)


@case
def changelog_data_is_well_formed():
    w, c = solo("Rai", guild_rank=3, tick=3)
    data = c.eval_py("return ns.CHANGELOG")
    assert data and len(data) >= 7, data
    seen = set()
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
            for line in s["lines"]:
                assert 0 < len(line) <= 90, (e["version"], line)
    assert data[-1]["version"] == "0.1.0"
    assert c.eval("local v = ...; for _, e in ipairs(ns.CHANGELOG) do if e.version == v then return true end end",
                  c.eval("return ns.version")), "the installed version has release notes"
    no_errors(w)


if __name__ == "__main__":
    run_all()
