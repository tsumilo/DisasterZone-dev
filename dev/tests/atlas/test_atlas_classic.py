"""Atlas tab, Classic | TBC (Data/AtlasClassic.lua, Core/Atlas.lua eras, the switch in UI/Atlas.lua): what a level
1-60 character can still get - the old world's raids, dungeons, professions, factions, battlegrounds, sets and world
events - behind a switch over the sources column.

Covers: the era by level (below 58 Classic, opening on the dungeon for my level; 70 TBC on the guild phase's raid), the
switch swapping the sources and keeping where I was in each era, a place in the other era (Select / a search result /
ShowItem) moving the switch along, search over the shown era with "In TBC" / "In Classic" for the other's matches,
Classic banners (loading screen, levels, size), no BiS adds for Classic items, the shipped data (names for every id, no
Season of Discovery, no Naxxramas / Tier 3), and a walk over every Classic page without Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\atlas\\test_atlas_classic.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, no_errors  # noqa: E402
import _common  # noqa: E402
from test_atlas import setup, rows, item_ids, state, menu_for, flat  # noqa: E402

del _common._CASES[:]   # (test_atlas.py's own cases: run by that file)

ARCANIST_BOOTS = 16800    # Molten Core, Lucifron (and Tier 1 Mage)
BONEREAVER = 17076        # Molten Core, Ragnaros
HARBINGER = 28477         # Karazhan, Attumen (TBC only)


def era(c):
    return c.eval("return ns.Atlas:GetEra()")


def cats(c):
    return [r[1] for r in rows(c, "src") if r[0] == "cat"]


@case
def a_level_20_opens_classic_on_the_dungeon_for_their_level():
    w, c = setup(level=20)
    assert era(c) == "classic"
    assert cats(c) == ["c_raids", "c_dungeons", "c_crafting", "c_reputation", "c_pvp", "c_events", "c_sets"], cats(c)
    st = state(c)
    # dungeons in level order; the last one starting at or below 22: Shadowfang Keep (18-21)
    assert st[0] == "c_dungeons" and st[1] == "ShadowfangKeep", st
    srcs = [r[1] for r in rows(c, "src") if r[0] == "src"]
    assert srcs[:4] == ["Ragefire", "WailingCaverns", "Deadmines", "ShadowfangKeep"], srcs
    assert c.eval("return ns.AtlasUI and ns.MainFrame:GetPanel('atlas').eraSeg:GetSelected()") == "classic"
    no_errors(w)


@case
def a_level_70_opens_tbc_and_the_switch_swaps_and_remembers():
    w, c = setup()
    assert era(c) == "tbc"
    assert cats(c)[0] == "raids" and "c_raids" not in cats(c)
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    seg = "ns.MainFrame:GetPanel('atlas').eraSeg"
    # the switch: Classic opens at its default (58+: the first raid), sources swap
    c.eval(seg + ":Select('classic', true)")
    assert era(c) == "classic"
    st = state(c)
    assert st[0] == "c_raids" and st[1] == "MoltenCore", st
    assert ARCANIST_BOOTS in item_ids(c)
    c.eval("ns.AtlasUI:Select('c_raids', 'BlackwingLair')")
    # back to TBC: where I was; then Classic again: Blackwing Lair
    c.eval(seg + ":Select('tbc', true)")
    assert state(c)[:3] == ["raids", "Karazhan", "Attumen"], state(c)
    assert HARBINGER in item_ids(c)
    c.eval(seg + ":Select('classic', true)")
    assert state(c)[:2] == ["c_raids", "BlackwingLair"], state(c)
    # a place in the other era moves the switch along
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    assert era(c) == "tbc", era(c)
    assert c.eval("return (" + seg + ":GetSelected())") == "tbc", c.eval("return (" + seg + ":GetSelected())")
    no_errors(w)


@case
def search_covers_the_shown_era_and_offers_the_other():
    w, c = setup()
    c.eval("ns.AtlasUI:SetSearch('bonereaver')")
    assert item_ids(c) == []
    found = c.eval_py("""local _, p = ns.AtlasUI:GetLists()
      local o = {} for i, d in ipairs(p:GetData()) do o[i] = { d.key or '', d.name, d.count } end return o""")
    assert found[-1] == ["@era", "In Classic", 1], found
    txt = c.eval("local _, _, l = ns.AtlasUI:GetLists(); return l.emptyText:GetText()") or ""
    assert "1 match in Classic" in txt, txt
    # a click on "In Classic" switches, the search stays
    c.eval("""local _, p = ns.AtlasUI:GetLists()
      for _, r in ipairs(p.box:GetFrames()) do
        local d = rawget(r, '__cdlData')
        if d and d.key == '@era' then r:Click() end
      end""")
    assert era(c) == "classic"
    assert item_ids(c) == [BONEREAVER], item_ids(c)
    assert rows(c)[0][3] == "Ragnaros  ·  Molten Core", rows(c)[0]
    # a click on the result opens Ragnaros' page
    c.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", BONEREAVER)
    assert state(c)[:3] == ["c_raids", "MoltenCore", "Ragnaros"], state(c)
    # ShowItem of a TBC item goes back to TBC
    c.eval("ns.AtlasUI:ShowItem(...)", HARBINGER)
    assert era(c) == "tbc" and state(c)[:2] == ["raids", "Karazhan"], state(c)
    no_errors(w)


@case
def classic_pages_have_their_art_and_levels_and_no_bis_adds():
    w, c = setup(level=40)
    assert era(c) == "classic"
    c.eval("ns.AtlasUI:Select('c_dungeons', 'ZulFarrak')")
    b = c.eval_py("""local b = ns.MainFrame:GetPanel('atlas').banner
      return { b:IsShown() and 1 or 0, b.sub and b.sub:GetText() or '' }""")
    assert b[0] == 1 and "Levels 42-46" in b[1], b
    src = [r for r in rows(c, "src") if r[0] == "src" and r[1] == "ZulFarrak"]
    assert src, rows(c, "src")
    c.eval("ns.AtlasUI:Select('c_raids', 'MoltenCore', 'Lucifron')")
    menu = flat(menu_for(c, ARCANIST_BOOTS))
    assert not any("BiS" in t or "Phase" in t for _, t in menu), menu
    assert any(t == "Try on" for _, t in menu), menu
    no_errors(w)


@case
def the_shipped_classic_data_is_whole_and_tbc_only():
    w, c = setup()
    bad = c.eval_py("""local out = {}
      local seen = {}
      for _, cat in ipairs(ns.Atlas:GetCategories(true)) do
        if cat.era == 'classic' then
          for _, src in ipairs(cat.sources) do
            if src.key:find('Naxx') or src.name:find('Season') then out[#out + 1] = src.key end
            for _, page in ipairs(src.pages) do
              if (page.name or ''):find('%(Sod%)') or (page.title or ''):find('Plagueheart') then
                out[#out + 1] = src.key .. '/' .. page.key end
              for _, id in ipairs(page.items) do
                if type(id) == 'number' and not ns.Atlas:GetShippedName(id) and not seen[id] then
                  seen[id] = true
                  out[#out + 1] = 'unnamed ' .. id
                end
              end
            end
          end
        end
      end
      return out""")
    assert bad == [], bad[:20]
    no_errors(w)


@case
def every_classic_page_draws_without_errors():
    w, c = setup(level=30)
    n = c.eval("""local n = 0
      for _, cat in ipairs(ns.Atlas:GetCategories(true)) do
        if cat.era == 'classic' then
          for _, src in ipairs(cat.sources) do
            for _, page in ipairs(src.pages) do
              ns.AtlasUI:Select(cat.key, src.key, page.key)
              n = n + 1
            end
          end
        end
      end
      return n""")
    assert n > 300, n
    no_errors(w)


if __name__ == "__main__":
    run_all()
