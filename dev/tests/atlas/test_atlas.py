"""Atlas tab (UI/Atlas.lua + Core/Atlas.lua + Data/Atlas.lua): the in-addon loot browser for every member.

Covers: the tab in the nav strip after My BiS, opening on the guild phase's raid, the source / page / item columns,
the categories of Data/Atlas.lua (and the other faction's sources left out), search by name / several words / item
number with a click opening the result's page, the "Usable by me" and slot filters, dungeon Normal / Heroic, craft
spells (enchants) as entries, the right-click menu adding an item to my BiS list (phase, best / alt, both ring slots,
"and later" filling only empty places, tier tokens resolving to my class's pieces, off spec, locked lists), the
marks (my list, owned, the council's "N want"), and a walk over every page without Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\atlas\\test_atlas.py [-k name]
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import (case, run_all, solo, no_errors, install_helpers, menu_texts, strip_codes,  # noqa: E402
                     tt_lines, plain)

# Karazhan, Attumen the Huntsman (Data/Items.lua)
GAUNTLETS = 28505     # Gauntlets of Renewed Hope: plate hands
SPECTRAL_BAND = 28510  # Spectral Band of Innervation: ring
HARBINGER = 28477     # Harbinger Bands: cloth wrist

LUA = r"""
function T_atlas() return ns.MainFrame:GetPanel("atlas") end
function T_atlas_rows(which)
  local s, p, i = ns.AtlasUI:GetLists()
  local list = (which == "src" and s) or (which == "page" and p) or i
  local out = {}
  for n, d in ipairs(list:GetData()) do
    if d.type == "item" then
      out[n] = { "item", d.id, d.x or "", d.loc and ns.Atlas:LocationText(d.loc) or "" }
    elseif d.type == "cat" then
      out[n] = { "cat", d.cat.key, d.expanded and 1 or 0 }
    elseif d.type == "src" then
      out[n] = { "src", d.src.key, d.cat.key }
    elseif d.type == "page" then
      out[n] = { "page", d.page.key, d.page.name }
    else
      out[n] = { d.type, d.text or "" }
    end
  end
  return out
end
function T_atlas_state()
  local s = ns.AtlasUI:GetState()
  return { s.cat or "", s.src or "", s.page or "", s.heroic and 1 or 0, s.search or "", s.selected or 0, s.expanded or "" }
end
-- the visible item row frame showing id (nil when it is not drawn)
function T_atlas_itemrow(id)
  local _, _, list = ns.AtlasUI:GetLists()
  for _, r in ipairs(list.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == "item" and d.id == id and r:IsShown() then return r end
  end
end
local function strip(s)
  s = tostring(s or "")
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T[^|]*|t", "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
-- invoke a menu entry by a path of label prefixes (colour codes and icons ignored)
function T_menu_path(path)
  local node = __MOCK.last_menu
  for i, want in ipairs(path) do
    local found
    for _, ch in ipairs(node.children) do
      local t = strip(ch.text)
      if t == want or t:sub(1, #want) == want then found = ch break end
    end
    if not found then error("menu path: no entry '" .. want .. "' at step " .. i) end
    node = found
  end
  if node.enabled == false then error("menu path: entry disabled") end
  return __MOCK.menu_select(node.text, node.parent)
end
"""


def setup(name="Alice", class_file="PALADIN", phase=1, faction="Alliance", **kw):
    w, c = solo(name, class_file=class_file, guild_rank=3, tick=4, council=[], phase=phase, faction=faction, **kw)
    install_helpers(c)
    c.eval(LUA)
    c.eval("ns.MainFrame:Open('atlas')")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "atlas"
    return w, c


def rows(c, which="item"):
    return [list(r) for r in (c.eval_py("return T_atlas_rows(...)", which) or [])]


def item_ids(c):
    return [r[1] for r in rows(c) if r[0] == "item"]


def state(c):
    return c.eval_py("return T_atlas_state()")


def menu_for(c, item_id, loc=False):
    c.eval("""local id, withLoc = ...
      local d = { type = 'item', id = id }
      if withLoc then d.loc = ns.Atlas:GetLocations(id)[1] end
      ns.AtlasUI:OpenMenu(d)""", item_id, loc)
    return c.last_menu()


def flat(menu):
    return [(e[0], strip_codes(e[2])) for e in menu_texts(menu)]


def pick(c, *path):
    c.eval("T_menu_path(...)", list(path))


def slot(c, phase, sid, lst=None):
    return c.eval_py("local p, s, l = ...; return { ns.BiS:GetSlot(p, s, l) }", phase, sid, lst) or []


# ------------------------------------------------------------------------------------------------------------------
@case
def tab_sits_after_my_bis_and_opens_on_the_guild_phase_raid():
    w, c = setup(phase=2)
    order = c.eval_py("""local o = {}
      for i, b in ipairs(ns.MainFrame:GetFrame().Tabs or {}) do o[i] = b.key or (b.GetText and b:GetText()) end
      return o""")
    labels = [str(x) for x in order]
    assert "atlas" in labels or "Atlas" in labels, labels
    st = state(c)
    first_p2 = c.eval("for _, r in ipairs(ns.Data.Raids) do if r.phase == 2 then return r.key end end")
    assert st[0] == "raids" and st[1] == first_p2, st
    first_boss = c.eval("local k = ...; for _, r in ipairs(ns.Data.Raids) do if r.key == k then return r.bosses[1].key end end", first_p2)
    assert st[2] == first_boss, st
    # left: the shopping list on top, Raids folded open with its raids; middle: the raid's bosses; right: the items
    src = rows(c, "src")
    assert src[0][0] == "shop" and src[1][:2] == ["cat", "raids"] and src[1][2] == 1, src[:3]
    assert any(r[0] == "src" and r[1] == first_p2 for r in src), src
    pages = rows(c, "page")
    n_bosses = c.eval("local k = ...; for _, r in ipairs(ns.Data.Raids) do if r.key == k then return #r.bosses end end", first_p2)
    assert len(pages) == n_bosses, (len(pages), n_bosses)
    expect = c.eval_py("local k, b = ...; for _, r in ipairs(ns.Data.Raids) do if r.key == k then return r.bosses[1].items end end",
                       first_p2, first_boss)
    assert item_ids(c) == list(expect), (item_ids(c)[:5], list(expect)[:5])
    no_errors(w)


@case
def categories_come_from_every_data_file_and_skip_the_other_faction():
    w, c = setup()
    cats = c.eval_py("local o = {} for i, cat in ipairs(ns.Atlas:GetCategories()) do o[i] = cat.key end return o")
    assert cats[:2] == ["raids", "dungeons"], cats
    for k in ("crafting", "reputation", "pvp", "vendors", "collections", "events", "sets"):
        assert k in cats, (k, cats)
    alliance = c.eval_py("local o = {} for i, s in ipairs(ns.Atlas:GetCategory('reputation').sources) do o[i] = s.key end return o")
    assert "HonorHold" in alliance and "Thrallmar" not in alliance, alliance
    w2, h = setup("Hordie", class_file="SHAMAN", faction="Horde")
    horde = h.eval_py("local o = {} for i, s in ipairs(ns.Atlas:GetCategory('reputation').sources) do o[i] = s.key end return o")
    assert "Thrallmar" in horde and "HonorHold" not in horde, horde
    # pages of one side only (e.g. faction mounts) are filtered too
    sides = h.eval_py("""local o = {}
      for _, cat in ipairs(ns.Atlas:GetCategories()) do
        for _, s in ipairs(cat.sources) do
          if s.side and s.side ~= 'Horde' then o[#o + 1] = s.key end
          for _, p in ipairs(s.pages) do if p.side and p.side ~= 'Horde' then o[#o + 1] = s.key .. '/' .. p.key end end
        end
      end
      return o""")
    assert not sides, sides
    no_errors(w)
    no_errors(w2)


@case
def data_file_shape_and_names_for_every_entry():
    w, c = setup()
    bad = c.eval_py("""local o = {}
      local names = ns.Data.AtlasNames
      for _, cat in ipairs(ns.Data.Atlas) do
        for _, s in ipairs(cat.sources) do
          for _, p in ipairs(s.pages) do
            if #p.items == 0 then o[#o + 1] = 'empty ' .. s.key .. '/' .. p.key end
            for _, e in ipairs(p.items) do
              if type(e) == 'number' and not names[e] then o[#o + 1] = 'noname ' .. e end
            end
          end
        end
      end
      for _, r in ipairs(ns.Data.Raids) do
        for _, b in ipairs(r.bosses) do
          for _, id in ipairs(b.items) do if not names[id] then o[#o + 1] = 'raid noname ' .. id end end
        end
      end
      return o""")
    assert not bad, bad[:10]
    # the data file is in the TOC, defines no globals
    assert c.eval("return rawget(_G, 'Atlas') == nil and rawget(_G, 'AtlasNames') == nil") is True
    no_errors(w)


@case
def search_by_name_words_and_number_and_click_opens_the_page():
    w, c = setup()
    c.eval("ns.AtlasUI:SetSearch('harbinger')")
    found = rows(c)
    ids = [r[1] for r in found if r[0] == "item"]
    assert HARBINGER in ids, ids
    loc = [r[3] for r in found if r[0] == "item" and r[1] == HARBINGER][0]
    assert loc == "Attumen the Huntsman  ·  Karazhan", loc
    # several words in any order, any case
    c.eval("ns.AtlasUI:SetSearch('BANDS harb')")
    assert HARBINGER in item_ids(c)
    # an item number
    c.eval("ns.AtlasUI:SetSearch(...)", str(HARBINGER))
    assert item_ids(c) == [HARBINGER]
    # one letter is not a search: the page's own rows stay (no result locations)
    c.eval("ns.AtlasUI:SetSearch('h')")
    assert rows(c) and all(r[3] == "" for r in rows(c) if r[0] == "item"), rows(c)[:3]
    # clicking a result opens Attumen's page with the item highlighted, the search cleared
    c.eval("ns.AtlasUI:SetSearch('harbinger')")
    w.tick(0.1)
    row = c.eval("return T_atlas_itemrow(...)", HARBINGER)
    assert row is not None
    c.click(row)
    st = state(c)
    assert st[:3] == ["raids", "Karazhan", "Attumen"] and st[4] == "" and st[5] == HARBINGER, st
    assert HARBINGER in item_ids(c)
    no_errors(w)


@case
def search_is_fast_over_everything_and_found_in_narrows_it():
    w, c = setup()
    t0 = time.time()
    n = c.eval("return #ns.Atlas:Search('of the')")
    dt = time.time() - t0
    assert n > 300, n
    assert dt < 2.0, dt
    c.eval("ns.AtlasUI:SetSearch('of the')")
    assert rows(c)[-1][0] == "more", rows(c)[-1:]
    # the middle column: where the matches are from, All first, with counts
    facets = rows(c, "page")
    assert facets[0][0] == "facet" or True
    found = c.eval_py("""local _, p = ns.AtlasUI:GetLists()
      local o = {} for i, d in ipairs(p:GetData()) do o[i] = { d.type, d.key or '', d.name, d.count } end return o""")
    assert found[0][:3] == ["facet", "", "All"] and found[0][3] == n, found[:2]
    keys = [f[1] for f in found[1:]]
    assert "raids" in keys and "pvp" in keys, keys
    assert sum(f[3] for f in found[1:]) == n
    # pick PvP: only PvP results, every one of them drawn when they fit
    pvp = [f for f in found if f[1] == "pvp"][0]
    c.eval("ns.AtlasUI:SetSearch('of the', 'pvp')")
    items = [r for r in rows(c) if r[0] == "item"]
    assert len(items) == min(pvp[3], 300), (len(items), pvp)
    assert c.eval("return ns.AtlasUI:GetState().facet") == "pvp"
    no_errors(w)


# Injected tooltip lines (the mock's tooltips have no stat lines)
STAT_LINES = r"""
local lines = ...
ns.Atlas.ScanItemLines = function(id) return lines[id] or {} end
"""
WHITE_STAG = 28453    # Bracers of the White Stag (Attumen): leather
STEELHAWK = 28504     # Steelhawk Crossbow (Attumen): paladins can't use crossbows


def inject_stats(c, lines):
    c.eval(STAT_LINES, {k: {i + 1: v for i, v in enumerate(vs)} for k, vs in lines.items()})


def show_options(c):
    opts = c.eval_py("local o = {} for i, x in ipairs(ns.Atlas:GetShowOptions()) do o[i] = { x.value, x.text } end return o") or []
    return [o[0] for o in opts], [o[1] for o in opts]


def page_data(c):
    return c.eval_py("""local _, _, list = ns.AtlasUI:GetLists()
      local o = {}
      for i, d in ipairs(list:GetData()) do o[i] = { d.id or 0, d.via or 0, d.viaKind or '' } end
      return o""") or []


@case
def show_my_class_keeps_lighter_armor():
    w, c = setup()
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    every = item_ids(c)
    assert HARBINGER in every and STEELHAWK in every and WHITE_STAG in every
    assert c.eval("return ns.DB:GetSetting('atlas.show')") == "all"
    assert c.eval("return T_button(T_atlas(), 'All items')") is not None
    c.eval("ns.DB:SetSetting('atlas.show', 'class'); ns.AtlasUI:RefreshItems()")
    mine = item_ids(c)
    # a paladin keeps cloth and leather (ret wears leather / mail pieces), loses the crossbow
    assert HARBINGER in mine and WHITE_STAG in mine and STEELHAWK not in mine, mine
    # non-gear stays (the mount / pattern on the page)
    non_gear = c.eval_py("local o = {} for _, id in ipairs(...) do if #ns.ItemDB:GetSlotsForItem(id) == 0 and not ns.Data.Tokens[id] then o[#o + 1] = id end end return o", every)
    for i in non_gear:
        assert i in mine, i
    # Sets: only my class remains in the middle column
    c.eval("ns.AtlasUI:Select('sets', 'Tier6')")
    names = [r[2] for r in rows(c, "page")]
    assert names == ["Paladin"], names
    no_errors(w)


@case
def sets_list_classes_and_each_class_its_sets_per_spec():
    w, c = setup()
    c.eval("ns.AtlasUI:Select('sets', 'Tier6')")
    names = [r[2] for r in rows(c, "page")]
    assert names == ["Druid", "Hunter", "Mage", "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior"], names
    # it opens on my class: a header per spec, then that set's pieces
    st = state(c)
    assert st[2] == "Paladin", st
    heads = [r[1] for r in rows(c) if r[0] == "header"]
    assert heads == ["Holy  ·  Lightbringer Raiment", "Protection  ·  Lightbringer Armor",
                     "Retribution  ·  Lightbringer Battlegear"], heads
    assert c.eval("return T_textregion(T_atlas(), 'Paladin') ~= nil") is True
    # a class with one set: the set's name alone
    c.eval("ns.AtlasUI:Select('sets', 'Tier6', 'Warlock')")
    heads = [r[1] for r in rows(c) if r[0] == "header"]
    assert heads == ["Malefic Raiment"], heads
    # set pieces say where they come from
    c.eval("ns.AtlasUI:Select('sets', 'Tier6', 'Paladin')")
    w.tick(0.2)
    ids = item_ids(c)
    row = c.eval("return T_atlas_itemrow(...)", ids[0])
    sub = strip_codes(c.eval("local r = ...; return r.sub:GetText()", row))
    assert "Token" in sub, sub
    # the spec filter keeps the Retribution set only (its header too)
    c.eval("ns.BiS:SetSpec('Retribution')")
    lines = {}
    for i in ids:
        lines[i] = ["+30 Strength"]
    holy = c.eval_py("local o = {} for _, p in ipairs(ns.Data.Atlas[7].sources[3].pages) do if p.name == 'Paladin (Heal)' then for _, id in ipairs(p.items) do o[#o + 1] = id end end end return o")
    for i in holy:
        lines[i] = ["+30 Intellect", "Equip: Increases healing done by up to 50 and damage done by up to 17 for all magical spells and effects."]
    inject_stats(c, lines)
    c.eval("ns.DB:SetSetting('atlas.show', 'spec'); ns.AtlasUI:RefreshItems()")
    heads = [r[1] for r in rows(c) if r[0] == "header"]
    assert "Holy  ·  Lightbringer Raiment" not in heads and "Retribution  ·  Lightbringer Battlegear" in heads, heads
    # every Sets source has a phase on the left
    phases = c.eval_py("local o = {} for _, s in ipairs(ns.Atlas:GetCategory('sets').sources) do o[#o + 1] = s.phase or 0 end return o")
    assert all(p >= 1 for p in phases), phases
    no_errors(w)


@case
def recipes_show_what_they_make_and_costs_read_well():
    w, c = setup()
    recipe, made = 29721, 29536   # Pattern: Nethercleft Leg Armor -> Nethercleft Leg Armor
    assert c.eval("return ns.Data.AtlasRecipes[...]", recipe) == made
    c.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", recipe)
    data = page_data(c)
    i = [d[0] for d in data].index(recipe)
    assert data[i + 1] == [made, recipe, "makes"], data[i:i + 2]
    # a PvP vendor page: the costs at the right with the currencies' icons, the whole cost in the tooltip
    # (tests/atlas/test_atlas_costs.py covers the costs and the currency bar)
    page, iid = c.eval_py("""for _, p in ipairs(ns.Atlas:GetSource('pvp', 'Honor').pages) do
        for _, id in ipairs(p.items) do if ns.Data.AtlasCosts[id] then return { p.key, id } end end end""")
    c.eval("ns.AtlasUI:Select('pvp', 'Honor', ...)", page)
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", iid)
    assert "|T" in c.eval("local r = ...; return r.mark:GetText()", row)
    c.hover(row)
    assert ("Cost", "") in [(strip_codes(l), strip_codes(r)) for l, r in tt_lines(c)], tt_lines(c)[-4:]
    names = c.eval_py("local o = {} for _, s in ipairs(ns.Atlas:GetCategory('pvp').sources) do o[#o + 1] = s.name end return o")
    assert "Honor rewards" in names and "PvP mounts" in names, names
    no_errors(w)


@case
def show_spec_judges_the_stats_not_the_armor_type():
    w, c = setup()
    c.eval("ns.BiS:SetSpec('Retribution')")
    vals, texts = show_options(c)
    assert vals == ["all", "class", "spec"] and texts[2] == "Retribution", (vals, texts)
    inject_stats(c, {
        HARBINGER: ["+15 Intellect", "Equip: Increases damage and healing done by magical spells and effects by up to 21."],
        GAUNTLETS: ["+24 Stamina", "+20 Intellect",
                    "Equip: Increases healing done by up to 44 and damage done by up to 15 for all magical spells and effects.",
                    "Equip: Restores 6 mana per 5 sec."],
        WHITE_STAG: ["+18 Strength", "+15 Stamina", "Equip: Improves critical strike rating by 14.", "Socket Bonus: +3 Intellect"],
        SPECTRAL_BAND: ["+15 Spirit", "Equip: Restores 6 mana per 5 sec."],
    })
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    c.eval("ns.DB:SetSetting('atlas.show', 'spec'); ns.AtlasUI:RefreshItems()")
    ret = item_ids(c)
    assert WHITE_STAG in ret, ret                       # leather with strength / crit: yes for ret
    for i in (HARBINGER, GAUNTLETS, SPECTRAL_BAND):     # caster / healer gear: no
        assert i not in ret, (i, ret)
    assert STEELHAWK not in ret                         # can't equip
    # an off spec adds its own choice; Holy keeps the healer gear and drops the strength bracers
    c.eval("ns.BiS:AddOffSpec('Holy')")
    vals, texts = show_options(c)
    assert vals == ["all", "class", "spec", "os"] and texts[3] == "Holy (off spec)", (vals, texts)
    c.eval("ns.DB:SetSetting('atlas.show', 'os'); ns.AtlasUI:RefreshItems()")
    holy = item_ids(c)
    assert GAUNTLETS in holy and SPECTRAL_BAND in holy and HARBINGER in holy and WHITE_STAG not in holy, holy
    # the role rules
    def rp(flags, role):
        return c.eval("local f, r = ...; return ns.Atlas.RolePasses(f, r)", flags, role)
    assert rp({"phys": True}, "melee") and not rp({"sp": True}, "melee")
    assert rp({"tank": True}, "tank") and rp({"phys": True}, "tank") and not rp({"heal": True}, "tank")
    assert rp({"shit": True}, "caster") and not rp({"heal": True}, "caster") and not rp({"phys": True}, "caster")
    assert rp({"sp": True}, "healer") and not rp({"shit": True}, "healer") and rp({}, "melee")
    # the off spec is gone: the remembered choice falls back to the main spec
    c.eval("ns.BiS:RemoveOffSpec()")
    assert c.eval("return ns.Atlas:ValidShow(ns.DB:GetSetting('atlas.show'))") == "spec"
    no_errors(w)


@case
def slot_filter():
    w, c = setup()
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    every = item_ids(c)
    c.eval("ns.AtlasUI:SetSlotFilter(11)")
    assert item_ids(c) == [SPECTRAL_BAND], item_ids(c)
    non_gear = c.eval_py("local o = {} for _, id in ipairs(...) do if #ns.ItemDB:GetSlotsForItem(id) == 0 then o[#o + 1] = id end end return o", every)
    c.eval("ns.AtlasUI:SetSlotFilter(0)")
    assert set(item_ids(c)) == set(non_gear), (item_ids(c), non_gear)
    c.eval("ns.AtlasUI:SetSlotFilter(nil)")
    assert item_ids(c) == every
    no_errors(w)


@case
def tokens_list_the_pieces_they_give_me():
    w, c = setup()
    token = 29760   # Helm of the Fallen Champion (Prince): Paladin, Rogue, Shaman
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Prince')")
    data = page_data(c)
    i = [d[0] for d in data].index(token)
    pieces = c.eval_py("local o = {} for _, p in ipairs(ns.Data.Tokens[...]) do if ns.Data.TierPieceClass[p] == 'PALADIN' then o[#o + 1] = p end end return o", token)
    kids = data[i + 1:i + 1 + len(pieces)]
    assert [k[0] for k in kids] == list(pieces) and all(k[1] == token and k[2] == "token" for k in kids), (kids, pieces)
    # the rows are indented and say where they come from
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", pieces[0])
    assert c.eval("local r = ...; return r.guide:IsShown()", row) is True
    c.hover(row)
    assert any("From " in l for l, _ in tt_lines(c)), tt_lines(c)
    # a piece can be added straight away
    menu_for(c, pieces[0])
    pick(c, "Add to my BiS list", "Phase 1", "As best")
    assert slot(c, 1, 1)[0] == pieces[0], slot(c, 1, 1)
    # the spec filter keeps the piece for my spec only
    c.eval("ns.BiS:SetSpec('Retribution')")
    inject_stats(c, {
        pieces[0]: ["+30 Intellect", "Equip: Increases healing done by up to 50 and damage done by up to 17 for all magical spells and effects."],
        pieces[1]: ["+40 Stamina", "Equip: Increases defense rating by 20."],
        pieces[2]: ["+30 Strength", "Equip: Improves critical strike rating by 20."],
    })
    c.eval("ns.DB:SetSetting('atlas.show', 'spec'); ns.AtlasUI:RefreshItems()")
    kids = [d[0] for d in page_data(c) if d[1] == token]
    assert kids == [pieces[2]], kids
    # a token only other classes use is hidden with My class
    other = c.eval("""for id, cl in pairs(ns.Data.TokenClasses) do
        local mine = false
        for _, k in ipairs(cl) do if k == 'PALADIN' then mine = true end end
        if not mine then return id end
      end""")
    assert c.eval("return ns.Atlas:PassesShow(..., 'class')", other) is False
    no_errors(w)


@case
def search_finds_tier_pieces_under_their_token():
    w, c = setup()
    piece = 29061   # Justicar Diadem, from Helm of the Fallen Champion (Prince)
    name = c.eval("return ns.Atlas:GetShippedName(...)", piece)
    assert name, "no shipped name for the piece"
    c.eval("ns.AtlasUI:SetSearch(...)", name)
    found = [r for r in rows(c) if r[0] == "item" and r[1] == piece]
    assert found and found[0][3] == "Prince Malchezaar  ·  Karazhan (token)", found
    w.tick(0.1)
    c.click(c.eval("return T_atlas_itemrow(...)", piece))
    st = state(c)
    assert st[:3] == ["raids", "Karazhan", "Prince"] and st[5] == piece, st
    # a piece of another class opens the page with its token highlighted
    rogue = c.eval("for _, p in ipairs(ns.Data.Tokens[29760]) do if ns.Data.TierPieceClass[p] == 'ROGUE' then return p end end")
    c.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", rogue)
    assert state(c)[5] == 29760, state(c)
    no_errors(w)


@case
def sunmote_items_and_their_drops_link_both_ways():
    w, c = setup()
    base, up = c.eval_py("for b, u in pairs(ns.Data.Upgrades) do return { b, u } end")
    # the Sunwell drop shows its Sunmote upgrade under it
    c.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", base)
    data = page_data(c)
    i = [d[0] for d in data].index(base)
    assert data[i + 1] == [up, base, "upgrade"], data[i:i + 2]
    # the Sunmote vendor: the upgraded item, the drop it's made from under it
    c.eval("ns.AtlasUI:Select('vendors', 'Sunmote')")
    pages = c.eval_py("local o = {} for _, p in ipairs(ns.Atlas:GetSource('vendors', 'Sunmote').pages) do o[#o + 1] = p.key end return o")
    seen = None
    for pk in pages:
        c.eval("ns.AtlasUI:Select('vendors', 'Sunmote', ...)", pk)
        data = page_data(c)
        for j, d in enumerate(data):
            if d[2] == "base":
                assert data[j - 1][0] == d[1], (data[j - 1], d)
                seen = seen or (pk, d[0])
    assert seen, "no base rows under the Sunmote items"
    # the row says how it works
    c.eval("ns.AtlasUI:Select('vendors', 'Sunmote', ...)", seen[0])
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", seen[1])
    assert row is not None
    sub = strip_codes(c.eval("local r = ...; return r.sub:GetText()", row))
    assert sub.startswith("Made from"), sub
    no_errors(w)


@case
def single_page_sources_have_no_page_list():
    w, c = setup()
    found = c.eval_py("""for _, cat in ipairs(ns.Atlas:GetCategories()) do
        for _, s in ipairs(cat.sources) do if #s.pages == 1 then return { cat.key, s.key } end end
      end""")
    assert found, "no single-page source"
    c.eval("ns.AtlasUI:Select(...)", found[0], found[1])
    _, p, _ = None, None, None
    shown = c.eval("local _, p = ns.AtlasUI:GetLists(); return p.frame:IsShown()")
    assert shown is False, found
    assert item_ids(c), found
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan')")
    assert c.eval("local _, p = ns.AtlasUI:GetLists(); return p.frame:IsShown()") is True
    no_errors(w)


@case
def dungeon_normal_and_heroic():
    w, c = setup()
    key = c.eval("""for _, d in ipairs(ns.Data.Dungeons) do
        for _, b in ipairs(d.bosses) do if b.heroicItems and #b.heroicItems > 0 and #b.items > 0 then return d.key end end
      end""")
    c.eval("ns.AtlasUI:Select('dungeons', ...)", key)
    boss = c.eval("""local k = ...; for _, d in ipairs(ns.Data.Dungeons) do if d.key == k then
        for _, b in ipairs(d.bosses) do if b.heroicItems and #b.heroicItems > 0 and #b.items > 0 then return b.key end end end end""", key)
    c.eval("local k, b = ...; ns.AtlasUI:Select('dungeons', k, b, false)", key, boss)
    normal = c.eval_py("local k, b = ...; for _, d in ipairs(ns.Data.Dungeons) do if d.key == k then for _, x in ipairs(d.bosses) do if x.key == b then return x.items end end end end", key, boss)
    heroic = c.eval_py("local k, b = ...; for _, d in ipairs(ns.Data.Dungeons) do if d.key == k then for _, x in ipairs(d.bosses) do if x.key == b then return x.heroicItems end end end end", key, boss)
    assert item_ids(c) == list(normal)
    tab = c.eval("return T_button(T_atlas(), 'Heroic')")
    assert c.eval("return T_visible(...)", tab) is True
    c.click(tab)
    assert item_ids(c) == list(heroic), (item_ids(c), list(heroic))
    # a raid has no Normal / Heroic tabs
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan')")
    assert c.eval("return T_visible(...)", tab) is False
    no_errors(w)


@case
def craft_spells_render_and_only_link():
    w, c = setup()
    src = c.eval_py("local o = {} for _, s in ipairs(ns.Atlas:GetCategory('crafting').sources) do o[#o + 1] = s.key end return o")
    assert "Enchanting" in src, src
    c.eval("ns.AtlasUI:Select('crafting', 'Enchanting')")
    ids = item_ids(c)
    spells = [i for i in ids if i < 0]
    assert spells, ids[:5]
    # skill text at the right
    assert any(r[2].startswith("Skill") for r in rows(c) if r[0] == "item"), rows(c)[:3]
    row = c.eval("return T_atlas_itemrow(...)", spells[0])
    name = strip_codes(c.eval("local r = ...; return r.name:GetText()", row))
    assert name == c.eval("return ns.Atlas:GetName(...)", spells[0]) and name, name
    c.hover(row)
    assert tt_lines(c), "no tooltip for a craft spell"
    texts = [t for _, t in flat(menu_for(c, spells[0]))]
    # (no BiS list entries for a spell; it can go on the shopping list)
    assert "Link in chat" in texts and "Add to shopping list" in texts, texts
    assert not any(t and t.startswith("Add to") and t != "Add to shopping list" for t in texts), texts
    no_errors(w)


@case
def right_click_adds_to_my_bis_best_and_alt():
    w, c = setup()
    menu = flat(menu_for(c, GAUNTLETS))
    top = [t for d, t in menu if d == 0]
    assert top[:2] == [c.eval("return ns.Atlas:GetName(...)", GAUNTLETS), "Add to my BiS list"], top
    assert "Try on" in top and "Link in chat" in top, top
    phases = [t for d, t in menu if d == 1]
    assert phases[0] == "Pre-raid", phases
    assert phases[1].startswith("Phase 1") and "(now)" in phases[1], phases
    assert "Phase 1 and later" in phases, phases
    pick(c, "Add to my BiS list", "Phase 1", "As best")
    assert slot(c, 1, 7) == [GAUNTLETS], slot(c, 1, 7)
    menu_for(c, HARBINGER)   # cloth: a paladin can still wear it
    pick(c, "Add to my BiS list", "Phase 2", "As alt")
    assert slot(c, 2, 6)[1:] == [HARBINGER] or slot(c, 2, 6) == [None, HARBINGER], slot(c, 2, 6)
    # the row shows the mark
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", GAUNTLETS)
    mark = strip_codes(c.eval("local r = ...; return r.mark:GetText()", row))
    assert "P1" in mark, mark
    no_errors(w)


@case
def pre_raid_entry_and_marks():
    w, c = setup()
    menu_for(c, GAUNTLETS)
    pick(c, "Add to my BiS list", "Pre-raid", "As best")
    assert slot(c, 0, 7) == [GAUNTLETS] and slot(c, 1, 7) == [], (slot(c, 0, 7), slot(c, 1, 7))
    marks = c.eval_py("local m = ns.Atlas:GetMyListMarks()[...] return m and m.main", GAUNTLETS)
    assert marks == {0: True} or marks == [True] or (isinstance(marks, dict) and set(marks) == {0}), marks
    # the row's mark names the Pre-raid list (before the raid phases)
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", GAUNTLETS)
    assert "Pre-raid" in strip_codes(c.eval("local r = ...; return r.mark:GetText()", row))
    for p in (1, 2, 3):
        c.eval("ns.BiS:SetSlot(..., 7, 'main', select(2, ...))", p, GAUNTLETS)
    assert c.eval("return ns.Atlas:PhasesText(ns.Atlas:GetMyListMarks()[...].main)", GAUNTLETS) == "Pre-raid, P1-3"
    assert c.eval("return ns.Atlas:PhasesText({ [0] = true })") == "Pre-raid"
    assert c.eval("return ns.Atlas:PhasesText({ [2] = true, [4] = true })") == "P2, P4"
    # the menu marks the Pre-raid entry as on the list
    pre = [e[2] for e in menu_texts(menu_for(c, GAUNTLETS)) if e[0] == 1 and (e[2] or "").startswith("Pre-raid")]
    assert len(pre) == 1 and "|T" in pre[0], pre      # (the check icon after the name)
    no_errors(w)


@case
def and_later_fills_only_empty_places():
    w, c = setup(phase=2)
    other = c.eval("for _, b in ipairs(ns.Data.Raids[1].bosses) do for _, id in ipairs(b.items) do if id ~= ... and ns.ItemDB:FitsSlot(id, 7) then return id end end end", GAUNTLETS)
    assert other
    c.eval("ns.BiS:SetSlot(4, 7, 'main', ...)", other)
    menu_for(c, GAUNTLETS)
    pick(c, "Add to my BiS list", "Phase 2 and later", "As best")
    assert slot(c, 1, 7) == [], slot(c, 1, 7)
    assert slot(c, 2, 7)[0] == GAUNTLETS and slot(c, 3, 7)[0] == GAUNTLETS and slot(c, 5, 7)[0] == GAUNTLETS
    assert slot(c, 4, 7)[0] == other, slot(c, 4, 7)
    no_errors(w)


@case
def rings_offer_both_slots():
    w, c = setup()
    menu = flat(menu_for(c, SPECTRAL_BAND))
    p1 = [t for d, t in menu if d == 2]
    assert "Ring 1  ·  As best" in p1 and "Ring 2  ·  As alt" in p1, p1
    pick(c, "Add to my BiS list", "Phase 1", "Ring 2  ·  As alt")
    assert slot(c, 1, 12) == [None, SPECTRAL_BAND] or slot(c, 1, 12)[1:] == [SPECTRAL_BAND], slot(c, 1, 12)
    no_errors(w)


@case
def tier_tokens_resolve_to_my_class_pieces():
    w, c = setup()
    token = c.eval("""for id, cl in pairs(ns.Data.TokenClasses) do
        for _, k in ipairs(cl) do if k == 'PALADIN' then return id end end
      end""")
    targets = c.eval_py("""local o = {}
      for i, t in ipairs(ns.Atlas:GetBiSTargets(...)) do o[i] = { t.itemID, ns.Data.TierPieceClass[t.itemID] or '', #t.sids } end
      return o""", token)
    assert targets and all(t[1] == "PALADIN" for t in targets), targets
    menu = flat(menu_for(c, token))
    assert any(t == "Add to my BiS list" for _, t in menu), menu
    if len(targets) > 1:
        p1 = [t for d, t in menu if d == 2]
        piece_name = c.eval("return ns.Atlas:GetName(...)", targets[0][0])
        assert any(t.startswith(piece_name + "  ·  ") for t in p1), (piece_name, p1)
        pick(c, "Add to my BiS list", "Phase 1", piece_name + "  ·  As best")
    else:
        pick(c, "Add to my BiS list", "Phase 1", "As best")
    sid = c.eval("return ns.ItemDB:GetSlotsForItem(...)[1]", targets[0][0])
    assert slot(c, 1, sid)[0] == targets[0][0], slot(c, 1, sid)
    # another class sees no add entries for it
    w2, m = setup("Mage", class_file="MAGE")
    if not m.eval("for _, k in ipairs(ns.Data.TokenClasses[...]) do if k == 'MAGE' then return true end end", token):
        texts = [t for _, t in flat(menu_for(m, token))]
        assert not any(t and t.startswith("Add to") for t in texts), texts
    no_errors(w)
    no_errors(w2)


@case
def off_spec_and_locked_lists():
    w, c = setup()
    c.eval("ns.BiS:AddOffSpec('Protection')")
    top = [t for d, t in flat(menu_for(c, GAUNTLETS)) if d == 0]
    assert any(t.startswith("Add to main spec") for t in top) and "Add to off spec (Protection)" in top, top
    pick(c, "Add to off spec", "Phase 1", "As best")
    assert slot(c, 1, 7, "os")[0] == GAUNTLETS and slot(c, 1, 7) == [], (slot(c, 1, 7, "os"), slot(c, 1, 7))
    # the raid leader locked the lists: no add entries, the reason as a title
    c.eval("ns.BiS.IsLocked = function() return true, { by = 'Lee-Realm', at = 0 } end")
    menu = flat(menu_for(c, GAUNTLETS))
    texts = [t for _, t in menu]
    assert any("BiS lists are locked by Lee" in (t or "") for t in texts), texts
    assert not any(t and t.startswith("Add to") for t in texts), texts
    assert "Link in chat" in texts
    no_errors(w)


@case
def hover_plus_adds_to_my_bis():
    w, c = setup()
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    w.tick(0.2)

    def plus_shown(item_id):
        row = c.eval("return T_atlas_itemrow(...)", item_id)
        assert row is not None, item_id
        c.hover(row)
        return row, c.eval("local r = ...; return r.plus:IsShown()", row)

    row, shown = plus_shown(GAUNTLETS)
    assert shown is True
    # the + menu goes straight to the phases (no off spec), the right-click menu's choices
    c.click(c.eval("local r = ...; return r.plus", row))
    top = [t for d, t in flat(c.last_menu()) if d == 0]
    assert top[0] == c.eval("return ns.Atlas:GetName(...)", GAUNTLETS) and top[1] == "Pre-raid", top
    assert top[2].startswith("Phase 1"), top
    pick(c, "Phase 1", "As best")
    assert slot(c, 1, 7) == [GAUNTLETS], slot(c, 1, 7)
    w.tick(0.3)
    # nothing to add for what isn't gear (the page's mount / pattern), nor for gear my class can't use
    ids = item_ids(c)
    non_gear = c.eval_py("local o = {} for _, id in ipairs(...) do if #ns.ItemDB:GetSlotsForItem(id) == 0 then o[#o + 1] = id end end return o", ids)
    assert non_gear and plus_shown(non_gear[0])[1] is False, non_gear
    assert plus_shown(STEELHAWK)[1] is False
    # the stars beside the boss count my picks there
    star = c.eval("""local _, p = ns.AtlasUI:GetLists()
      for _, r in ipairs(p.box:GetFrames()) do
        local d = rawget(r, '__cdlData')
        if d and d.page and d.page.key == 'Attumen' then return r.tag:GetText() end
      end""")
    assert strip_codes(star or "").strip() == "1", star
    # locked lists: no + at all
    c.eval("ns.BiS.IsLocked = function() return true, { by = 'Lee-Realm', at = 0 } end; ns.AtlasUI:RefreshItems()")
    w.tick(0.2)
    assert plus_shown(HARBINGER)[1] is False
    no_errors(w)


@case
def class_restricted_items_cannot_be_added():
    w, c = setup()
    item = c.eval("for id, cl in pairs(ns.Data.ItemClasses) do if #cl == 1 and cl[1] == 'ROGUE' and #ns.ItemDB:GetSlotsForItem(id) > 0 then return id end end")
    texts = [t for _, t in flat(menu_for(c, item))]
    assert "Your class can't use this" in texts and not any(t and t.startswith("Add to") for t in texts), texts
    no_errors(w)


@case
def council_sees_how_many_want_an_item():
    w, c = setup()
    c.eval("ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen')")
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", GAUNTLETS)
    assert "want" not in (strip_codes(c.eval("local r = ...; return r.mark:GetText()", row)) or "")
    c.eval("""local target = ...
      ns.Guild.AmICouncil = function() return true end
      local orig = ns.Store.GetWanters
      ns.Store.GetWanters = function(self, id, opts)
        if id == target then return { { key = 'Bob-Realm' }, { key = 'Cid-Realm' }, { key = 'Bob-Realm' } } end
        return orig(self, id, opts)
      end""", GAUNTLETS)
    c.eval("ns.AtlasUI:RefreshItems()")
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", GAUNTLETS)
    assert "2 want" in strip_codes(c.eval("local r = ...; return r.mark:GetText()", row))
    no_errors(w)


@case
def every_page_opens_without_errors():
    w, c = setup()
    n = c.eval("""local n = 0
      for _, cat in ipairs(ns.Atlas:GetCategories()) do
        for _, s in ipairs(cat.sources) do
          for _, p in ipairs(s.pages) do
            ns.AtlasUI:Select(cat.key, s.key, p.key, false)
            n = n + 1
            if p.heroicItems then ns.AtlasUI:Select(cat.key, s.key, p.key, true) end
          end
        end
      end
      return n""")
    assert n > 200, n
    w.tick(1)
    no_errors(w)


if __name__ == "__main__":
    run_all()
