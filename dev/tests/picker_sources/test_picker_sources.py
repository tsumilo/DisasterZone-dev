"""ADDENDUM F §35 / §37: item picker sources (raids, 5-man dungeons, crafted, reputation, badge vendors, PvP) and
the Data/Sources.lua integration in ItemDB (GetCandidates filter.sources, GetSources kinds, GetSourceText,
GetSourceKind, Search), on the real addon.

Covers: the data file + TOC order, GetCandidates for several class / slot combos per source kind (checked against
an independent walk of ns.Data), PvP / side-only reputation faction filtering (Alliance vs Horde), the default
sources (Raids + 5-man dungeons), toggles adding sections and persisting across a relog, search by profession /
faction / vendor / season, row subtitles and source texts, the phase filter on every source, GetSources scopes,
the auto-ledger ignoring non-drop sources (Loot uses the "drops" scope) and a speed check for all sources on one
slot.

Run: luaenv\\Scripts\\python.exe tests\\picker_sources\\test_picker_sources.py [-k name]
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, menu_texts,  # noqa: E402
                     strip_codes, tt_lines)

SOURCE_KEYS = ["raids", "dungeons", "crafted", "rep", "badges", "pvp"]
DEFAULT = {"raids": True, "dungeons": True, "crafted": False, "rep": False, "badges": False, "pvp": False}
ALL_ON = {k: True for k in SOURCE_KEYS}
DASH = " \u2014 "

# Items from Data/Sources.lua (names from its comments)
DIRGE = 23555                  # Blacksmithing (365), general, P1, 2H mace
EMBRACE = 23565                # Blacksmithing (375) Armorsmith, P2, "2x Nether Vortex", chest
TWISTING_SHIRT = 23564         # Blacksmithing (375) Armorsmith, P1, chest (mail)
BULWARK_ANCIENT = 28485        # Blacksmithing (375) Armorsmith, P2, "2x Nether Vortex", plate chest
BULWARK_KINGS = 28484          # Blacksmithing (375) Armorsmith, P1, plate chest
LIGHTBEARER = 29123            # The Aldor, Exalted, neck
MANA_BINDERS = 32089           # G'eras, 50 badges, head
ANGELISTA = 34887              # Anwehu, 60 badges, P5 ring
GLAD_DREADWEAVE_HOOD = 24553   # Arena Season 1, head
MARSHAL_SILK_CUFFS = 29002     # Arena Season 1, Alliance only, wrist
GENERAL_SILK_CUFFS = 28411     # Arena Season 1, Horde only, wrist
MEDALLION_ALLIANCE = 28235     # Honor vendors, 8000 honor, Alliance, neck

KIND_FLAG = {"craft": "crafted", "rep": "rep", "badge": "badges", "pvp": "pvp"}
KIND_DATA = {"craft": "Crafted", "rep": "Reputation", "badge": "Badges", "pvp": "PvP"}

# Independent expectation: walk ns.Data.<X> in order and keep the items that fit / pass the same filters.
EXPECTED_LUA = r"""
local sid, kind, dataName, klass, maxPhase, faction, primary = ...
local DB = ns.ItemDB
local out, seen = {}, {}
for _, g in ipairs(ns.Data[dataName]) do
  for _, it in ipairs(g.items) do
    local id = it.id
    local p = tonumber(it.phase) or tonumber(g.phase) or 1
    local fac = (kind == 'pvp' and it.faction) or (kind == 'rep' and g.side) or nil
    if not seen[id] and DB:FitsSlot(id, sid) and p <= maxPhase and (fac == nil or fac == faction)
       and (klass == '' or DB:IsUsableBy(id, klass, sid) ~= false)
       and (not primary or klass == '' or DB:IsPrimaryArmor(id, klass)) then
      seen[id] = true
      out[#out + 1] = id
    end
  end
end
return out"""

CANDS_LUA = r"""
local sid, f = ...
local out = {}
for i, r in ipairs(ns.ItemDB:GetCandidates(sid, f)) do
  out[i] = { r.itemID, r.kind or '', r.groupKey or '', r.groupName or '', r.subgroup or '', r.phase or 0,
             r.faction or '', r.standing or '', tostring(r.cost or ''), r.skill or 0 }
end
return out"""

PICKER_ROWS = r"""
local out = {}
for i, d in ipairs(T_data(T_box(DisasterZonePicker))) do
  out[i] = { d.type, d.name or '', d.itemID or 0, d.kind or '', d.groupName or '', d.subgroup or '',
             (d.src and d.src.faction) or '', (d.src and d.src.phase) or 0 }
end
return out"""

PICKER_SUBS = r"""
local out = {}
for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do
  local d = rawget(r, "__cdlData")
  if d and d.type == 'item' then
    out[#out + 1] = { d.itemID, d.kind or '', r.sub:GetText() or '', ns.ItemDB:FormatSource(d.src, false) or '' }
  end
end
return out"""


# ------------------------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------------------------
def setup(name="Alice", class_file="PALADIN", talents=(41, 20, 0), **kw):
    w, c = solo(name, class_file=class_file, guild_rank=3, tick=4, council=[], phase=1, talents=talents, **kw)
    install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "mybis"
    return w, c


def tile_btn(c, sid, which="main"):
    return c.eval("local s, w = ...; return T_tile(s)[w]", sid, which)


def open_picker(c, sid, which="main"):
    c.click(tile_btn(c, sid, which))
    assert c.eval("return ns.Picker:IsOpen()") is True, "picker did not open for sid %d" % sid


def rows(c):
    return c.eval_py(PICKER_ROWS) or []


def headers(c):
    return [r[1] for r in rows(c) if r[0] == "raid"]


def subheaders(c):
    return [r[1] for r in rows(c) if r[0] == "boss"]


def items(c):
    return [r for r in rows(c) if r[0] == "item"]


def sources_dd(c):
    return c.eval("return T_multi_dropdown(DisasterZonePicker)")


def phase_dd(c):
    return c.eval("return T_dropdown(DisasterZonePicker, '-')")


def set_sources(c, **on):
    for k in SOURCE_KEYS:
        c.eval("ns.Picker:SetSourceEnabled(...)", k, bool(on.get(k, False)))


def summary(c):
    """The Sources button text (what the game shows)."""
    return c.eval("local d = ...; return d:GetText()", sources_dd(c))


def search_box(c):
    return c.eval("return T_template(DisasterZonePicker, 'SearchBoxTemplate')[1]")


def cands(c, sid, **f):
    return c.eval_py(CANDS_LUA, sid, f) or []


def expected(c, sid, kind, klass="", max_phase=5, faction="Alliance", primary=False):
    return c.eval_py(EXPECTED_LUA, sid, kind, KIND_DATA[kind], klass, max_phase, faction, primary) or []


def sources_of(c, item_id, scope=None):
    return c.eval_py("""
      local id, scope = ...
      local out = {}
      for i, e in ipairs(ns.ItemDB:GetSources(id, scope)) do
        local copy = {}
        for k, v in pairs(e) do if type(v) ~= 'table' then copy[k] = v end end
        out[i] = copy
      end
      return out""", item_id, scope) or []


# ------------------------------------------------------------------------------------------------------------------
@case
def data_file_loaded_in_toc_order_without_globals():
    w, c = solo("Alice", tick=2)
    counts = c.eval_py("""
      local o = {}
      for _, k in ipairs({ 'Crafted', 'Reputation', 'Badges', 'PvP' }) do
        local n, g = 0, 0
        for _, grp in ipairs(ns.Data[k] or {}) do
          g = g + 1
          n = n + #grp.items
        end
        o[k] = { g, n }
      end
      return o""")
    for k in ("Crafted", "Reputation", "Badges", "PvP"):
        assert counts[k][0] > 0 and counts[k][1] > 0, (k, counts[k])
    groups = c.eval_py("local o = {} for i, g in ipairs(ns.Data.Crafted) do o[i] = g.key end return o")
    assert groups[:5] == ["Blacksmithing", "Leatherworking", "Tailoring", "Jewelcrafting", "Engineering"], groups
    pvp = c.eval_py("local o = {} for i, g in ipairs(ns.Data.PvP) do o[i] = g.key end return o")
    assert pvp[:5] == ["S1", "S2", "S3", "S4", "Honor"], pvp
    # the file is in the TOC right after Data\Dungeons.lua, and defines no globals
    toc_path = os.path.join(w.addon_dir, "DisasterZone.toc")
    lines = [l.strip() for l in open(toc_path, encoding="utf-8").read().splitlines()]
    files = [l for l in lines if l and not l.startswith("#")]
    i_d, i_s, i_db = files.index("Data\\Dungeons.lua"), files.index("Data\\Sources.lua"), files.index("Core\\ItemDB.lua")
    assert i_s == i_d + 1 and i_s < i_db, files
    assert c.eval("return rawget(_G, 'Crafted') == nil and rawget(_G, 'Data') == nil")
    no_errors(w)


@case
def default_sources_are_raids_and_dungeons():
    w, c = setup()
    assert c.eval_py("return ns.db.settings.pickerSources") == DEFAULT
    open_picker(c, 5)
    assert c.eval_py("return ns.Picker:GetSources()") == DEFAULT
    assert summary(c) == "Raids + 5-man"
    kinds = {r[3] for r in items(c)}
    assert kinds == {"raid", "dungeon"}, kinds
    hs = headers(c)
    first5 = next(i for i, h in enumerate(hs) if h.endswith("(5-man)"))
    assert first5 > 0 and all(h.endswith("(5-man)") for h in hs[first5:]), hs
    # the sources menu: title + one checkbox per source, Raids and 5-man ticked
    menu = c.dropdown_menu(sources_dd(c))
    entries = [(e[1], e[2]) for e in menu_texts(menu)]
    assert entries == [("title", "Show items from"), ("checkbox", "Raids"), ("checkbox", "5-man dungeons"),
                       ("checkbox", "Crafted"), ("checkbox", "Reputation"), ("checkbox", "Badge vendors"),
                       ("checkbox", "PvP")], entries
    ticked = [ch.get("text") for ch in menu.get("children") or [] if ch.get("kind") == "checkbox" and ch.get("selected")]
    assert ticked == ["Raids", "5-man dungeons"], ticked
    # ItemDB: callers without filter.sources keep the old scopes (default = raids only)
    old = cands(c, 5, maxPhase=1)
    assert old and {r[1] for r in old} == {"raid"}, {r[1] for r in old}
    scope_all = [r[0] for r in cands(c, 5, maxPhase=1, scope="all")]
    by_sources = [r[0] for r in cands(c, 5, maxPhase=1, sources={"raids": True, "dungeons": True})]
    assert scope_all == by_sources and len(scope_all) > len(old), (len(scope_all), len(by_sources), len(old))
    assert [r[0] for r in cands(c, 5, maxPhase=1, scope="dungeons")] == \
        [r[0] for r in cands(c, 5, maxPhase=1, sources={"dungeons": True})]
    # sources = {} (nothing ticked) -> nothing, even with a scope given
    assert cands(c, 5, maxPhase=1, scope="all", sources={}) == []
    no_errors(w)


@case
def candidates_per_kind_match_the_data_for_class_slot_combos():
    w, c = solo("Alice", tick=2)
    combos = [
        # kind, sid, class, primary armor only
        ("craft", 5, "PALADIN", True), ("craft", 5, "MAGE", True), ("craft", 7, "ROGUE", True),
        ("craft", 15, "WARRIOR", False), ("craft", 11, "HUNTER", False), ("craft", 13, "PRIEST", False),
        ("rep", 11, "MAGE", False), ("rep", 2, "WARRIOR", False), ("rep", 1, "PRIEST", True),
        ("rep", 17, "HUNTER", False),
        ("badge", 1, "MAGE", True), ("badge", 13, "WARRIOR", False), ("badge", 17, "PALADIN", False),
        ("badge", 16, "SHAMAN", False),
        ("pvp", 5, "WARRIOR", True), ("pvp", 1, "WARLOCK", True), ("pvp", 13, "ROGUE", False),
        ("pvp", 15, "PRIEST", False),
    ]
    problems = []
    for kind, sid, klass, primary in combos:
        f = {"sources": {KIND_FLAG[kind]: True}, "maxPhase": 5, "class": klass, "usableOnly": True,
             "primaryArmorOnly": primary}
        got = cands(c, sid, **f)
        want = expected(c, sid, kind, klass, 5, "Alliance", primary)
        ids = [r[0] for r in got]
        if not got:
            problems.append("%s sid %d %s: no rows" % (kind, sid, klass))
        if ids != want:
            problems.append("%s sid %d %s: ids differ (got %d, want %d): extra %r missing %r" % (
                kind, sid, klass, len(ids), len(want), sorted(set(ids) - set(want))[:5], sorted(set(want) - set(ids))[:5]))
        for r in got:
            iid, rk, gkey, gname = r[0], r[1], r[2], r[3]
            if rk != kind or not gkey or not gname:
                problems.append("%s sid %d: row %r lacks kind / group" % (kind, sid, r))
            if not c.eval("return ns.ItemDB:FitsSlot(...)", iid, sid):
                problems.append("%s sid %d: %d does not fit" % (kind, sid, iid))
            if r[5] < 1 or r[5] > 5:
                problems.append("%s sid %d: %d phase %r" % (kind, sid, iid, r[5]))
            if kind == "craft" and not r[9]:
                problems.append("craft %d without skill" % iid)
            if kind == "rep" and r[7] not in ("Friendly", "Honored", "Revered", "Exalted"):
                problems.append("rep %d standing %r" % (iid, r[7]))
            if kind == "badge" and not r[8]:
                problems.append("badge %d without cost" % iid)
            if r[6] == "Horde":
                problems.append("%s sid %d: Horde row %d for an Alliance player" % (kind, sid, iid))
        # section order: data group order; inside a profession the general recipes come before the specs
        order = c.eval_py("local k, o = ..., {} for i, g in ipairs(ns.Data[k]) do o[g.key] = i end return o",
                          KIND_DATA[kind])
        seq = [order[r[2]] for r in got]
        if seq != sorted(seq):
            problems.append("%s sid %d: groups out of data order %r" % (kind, sid, [r[2] for r in got][:12]))
    assert not problems, "\n".join(problems[:30])
    # the class filters really filter: a mage gets no plate from Blacksmithing, a paladin no cloth
    mage = cands(c, 5, sources={"crafted": True}, maxPhase=5, **{"class": "MAGE", "usableOnly": True,
                                                                  "primaryArmorOnly": True})
    # (the mock guesses the slot of some items without data - e.g. goggles - so only the armor classes are checked)
    groups = {r[3] for r in mage}
    assert mage and "Tailoring" in groups and not groups & {"Blacksmithing", "Leatherworking"}, groups
    pal = cands(c, 5, sources={"crafted": True}, maxPhase=5, **{"class": "PALADIN", "usableOnly": True,
                                                                 "primaryArmorOnly": True})
    assert {r[3] for r in pal} == {"Blacksmithing"} and BULWARK_ANCIENT in [r[0] for r in pal], pal[:5]
    assert EMBRACE not in [r[0] for r in pal], "mail chest offered with 'my armor type only'"
    assert [r[4] for r in pal if r[0] == BULWARK_ANCIENT] == ["Armorsmith"]
    # one item listed once even when several kinds are ticked (first source wins: raid before crafted ...)
    both = cands(c, 13, sources=ALL_ON, maxPhase=5, faction="any")
    ids = [r[0] for r in both]
    assert len(ids) == len(set(ids)), "duplicate rows"
    kinds = [r[1] for r in both]
    rank = {"raid": 0, "dungeon": 1, "craft": 2, "rep": 3, "badge": 4, "pvp": 5}
    assert [rank[k] for k in kinds] == sorted(rank[k] for k in kinds), "sections out of order"
    assert set(kinds) == set(rank), set(kinds)
    no_errors(w)


@case
def pvp_and_side_reputation_rows_only_for_my_faction():
    w = World()
    ally = Client(w, "Alice", guild_rank=3, class_file="MAGE")
    horde = Client(w, "Hordo", guild=None, class_file="MAGE", faction="Horde", race="Orc")
    for x in (ally, horde):
        x.load_addon()
    w.tick(2)
    count = r"""
      local mine = UnitFactionGroup('player')
      local n, own, other, sides = 0, 0, 0, {}
      for sid = 1, 17 do
        for _, r in ipairs(ns.ItemDB:GetCandidates(sid, { sources = { pvp = true, rep = true }, maxPhase = 5 })) do
          n = n + 1
          if r.faction then
            if r.faction == mine then own = own + 1 else other = other + 1 end
            sides[r.groupKey] = r.faction
          end
        end
      end
      return { n, own, other, sides }"""
    a = ally.eval_py(count)
    h = horde.eval_py(count)
    assert a[1] > 0 and a[2] == 0 and h[1] > 0 and h[2] == 0, (a[:3], h[:3])
    assert a[3].get("HonorHold") == "Alliance" and "Thrallmar" not in a[3], a[3]
    assert h[3].get("Thrallmar") == "Horde" and "HonorHold" not in h[3], h[3]
    # wrist, S1: Marshal's for the Alliance mage, General's for the Horde mage
    a6 = [r[0] for r in cands(ally, 6, sources={"pvp": True}, maxPhase=1)]
    h6 = [r[0] for r in cands(horde, 6, sources={"pvp": True}, maxPhase=1)]
    assert MARSHAL_SILK_CUFFS in a6 and GENERAL_SILK_CUFFS not in a6, a6[:10]
    assert GENERAL_SILK_CUFFS in h6 and MARSHAL_SILK_CUFFS not in h6, h6[:10]
    # neutral items (no faction tag) are listed for both
    assert GLAD_DREADWEAVE_HOOD in [r[0] for r in cands(ally, 1, sources={"pvp": True}, maxPhase=1)]
    assert GLAD_DREADWEAVE_HOOD in [r[0] for r in cands(horde, 1, sources={"pvp": True}, maxPhase=1)]
    # filter.faction overrides: "any" shows both sides, "Horde" only Horde + neutral
    anyf = [r for r in cands(ally, 6, sources={"pvp": True}, maxPhase=1, faction="any")]
    assert {MARSHAL_SILK_CUFFS, GENERAL_SILK_CUFFS} <= {r[0] for r in anyf}
    hf = cands(ally, 6, sources={"pvp": True}, maxPhase=1, faction="Horde")
    assert GENERAL_SILK_CUFFS in [r[0] for r in hf] and not [r for r in hf if r[6] == "Alliance"]
    # the Horde player's picker (PvP ticked) shows no Alliance item, and tags its faction items
    install_helpers(horde)
    horde.slash("/dz bis")
    w.tick(0.3)
    open_picker(horde, 13)   # (the Medallions are trinkets: the mock's equipLoc now matches the client)
    set_sources(horde, pvp=True)
    pv = items(horde)
    assert pv and all(r[3] == "pvp" for r in pv), pv[:3]
    assert not [r for r in pv if r[6] == "Alliance"], [r for r in pv if r[6] == "Alliance"][:3]
    tagged = [s for s in horde.eval_py(PICKER_SUBS) if s[0] in {r[2] for r in pv if r[6] == "Horde"}]
    assert tagged and all("(Horde)" in s[2] for s in tagged), tagged[:3]
    no_errors(w)


@case
def ticking_sources_adds_sections_in_order():
    w, c = setup()
    open_picker(c, 5)
    c.dropdown_menu(phase_dd(c))
    c.menu_select("All phases")
    sdd = sources_dd(c)
    base = headers(c)
    c.dropdown_menu(sdd)
    c.menu_select("Crafted")
    assert c.eval("return ns.db.settings.pickerSources.crafted") is True
    hs = headers(c)
    assert hs[:len(base)] == base, "raid / dungeon sections stay first"
    new = hs[len(base):]
    assert new == ["Crafted" + DASH + "Blacksmithing"], new
    assert subheaders(c)[-1:] == ["Armorsmith"], subheaders(c)[-3:]
    # general recipes come before the specialisation sub-header
    rs = rows(c)
    start = next(i for i, r in enumerate(rs) if r[0] == "raid" and r[1] == "Crafted" + DASH + "Blacksmithing")
    sec = rs[start + 1:]
    sub_at = next(i for i, r in enumerate(sec) if r[0] == "boss")
    assert sub_at > 0 and all(r[0] == "item" and r[5] == "" for r in sec[:sub_at]), sec[:sub_at + 1]
    assert all(r[0] == "item" and r[5] == "Armorsmith" for r in sec[sub_at + 1:]), sec[sub_at + 1:]
    # the section header counts its items
    cnt = c.eval("for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do local d = rawget(r, '__cdlData') "
                 "if d and d.type == 'raid' and d.kind == 'craft' then return r.count:GetText() end end")
    assert cnt == "%d items" % len([r for r in sec if r[0] == "item"]), cnt
    for label, flag in (("Reputation", "rep"), ("Badge vendors", "badges"), ("PvP", "pvp")):
        c.dropdown_menu(sdd)
        c.menu_select(label)
        assert c.eval_py("return ns.Picker:GetSources()")[flag] is True
    hs = headers(c)
    kinds_in_order = [h.split(DASH)[0] for h in hs[len(base):]]
    firsts = []
    for k in kinds_in_order:
        if k not in firsts:
            firsts.append(k)
    assert firsts == ["Crafted", "Reputation", "Badge of Justice", "PvP"], hs[len(base):]
    assert "Badge of Justice" + DASH + "G'eras" in hs, hs
    assert "PvP" + DASH + "Arena Season 1 (Gladiator)" in hs and "PvP" + DASH + "Honor vendors" in hs, hs
    assert not any(h == "PvP" + DASH + "Arena Season 4 (Brutal Gladiator)" for h in hs[:hs.index("PvP" + DASH + "Arena Season 1 (Gladiator)")])
    assert summary(c) == "All sources", summary(c)
    # the Reset entry appears once the choice differs from the default, and restores it
    menu = c.dropdown_menu(sdd)
    assert "Reset to raids + 5-man dungeons" in [e[2] for e in menu_texts(menu)]
    c.menu_select("Reset to raids + 5-man dungeons")
    assert c.eval_py("return ns.Picker:GetSources()") == DEFAULT
    assert {r[3] for r in items(c)} == {"raid", "dungeon"}
    # nothing ticked: explanatory empty text
    set_sources(c)
    assert items(c) == []
    assert c.eval("return T_textregion(DisasterZonePicker, 'No sources ticked'):IsVisible()") is True
    no_errors(w)


@case
def source_toggles_persist_for_the_session_and_across_relog():
    w, c = setup()
    open_picker(c, 1)
    sdd = sources_dd(c)
    c.dropdown_menu(sdd)
    c.menu_select("5-man dungeons")          # off
    c.dropdown_menu(sdd)
    c.menu_select("Badge vendors")           # on
    c.dropdown_menu(sdd)
    c.menu_select("PvP")                     # on
    want = {"raids": True, "dungeons": False, "crafted": False, "rep": False, "badges": True, "pvp": True}
    assert c.eval_py("return ns.Picker:GetSources()") == want
    assert c.eval_py("return ns.db.settings.pickerSources") == want
    # the session: another slot keeps the choice
    c.eval("ns.Picker:Close()")
    open_picker(c, 3)
    assert c.eval_py("return ns.Picker:GetSources()") == want
    kinds = {r[3] for r in items(c)}
    assert kinds <= {"raid", "badge", "pvp"} and "pvp" in kinds, kinds
    c.eval("ns.Picker:Close()")
    # /reload: saved in SavedVariables, the picker opens with it
    c.relog()
    w.tick(3)
    install_helpers(c)
    assert c.eval_py("return ns.db.settings.pickerSources") == want
    c.slash("/dz bis")
    w.tick(0.3)
    open_picker(c, 3)
    assert c.eval_py("return ns.Picker:GetSources()") == want
    kinds = {r[3] for r in items(c)}
    assert "dungeon" not in kinds and "pvp" in kinds, kinds
    assert summary(c) == "Raids + 2 more", summary(c)
    # full logout / login too
    c.relog(reload=False)
    w.tick(3)
    assert c.eval_py("return ns.db.settings.pickerSources") == want
    # a damaged saved value falls back to the defaults per key
    c.eval("ns.db.settings.pickerSources = { raids = 'yes', pvp = true, crafted = 3 }")
    c.relog()
    w.tick(3)
    install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    open_picker(c, 3)
    got = c.eval_py("return ns.Picker:GetSources()")
    assert got["raids"] is True and got["pvp"] is True and got["crafted"] is False and got["dungeons"] is True, got
    no_errors(w)


@case
def saved_variables_from_03_get_the_default_sources():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", "{ schema = 1, settings = { roll = { duration = 45 }, dungeon = { enabled = true } },"
                                     " chars = {}, lists = {} }")
    c.load_addon()
    w.tick(2)
    assert c.eval_py("return ns.db.settings.pickerSources") == DEFAULT
    assert c.eval("return ns.db.settings.roll.duration") == 45
    install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    open_picker(c, 1)
    assert c.eval_py("return ns.Picker:GetSources()") == DEFAULT
    no_errors(w)


@case
def search_by_profession_faction_vendor_and_season():
    w, c = setup()
    open_picker(c, 5)
    c.dropdown_menu(phase_dd(c))
    c.menu_select("All phases")
    set_sources(c, **ALL_ON)
    sb = search_box(c)

    def search(text):
        c.type_text(sb, text)
        w.tick(0.3)
        return items(c)

    got = search("blacksmithing")
    assert got and all(r[3] == "craft" and r[4] == "Blacksmithing" for r in got), got[:5]
    got = search("ARMORSMITH")
    assert got and all(r[5] == "Armorsmith" for r in got) and BULWARK_ANCIENT in [r[2] for r in got], got[:5]
    got = search("season 2")
    assert got and all(r[3] == "pvp" and r[4].startswith("Arena Season 2") for r in got), got[:5]
    got = search("g'eras")
    assert got and all(r[3] == "badge" and r[4] == "G'eras" for r in got), got[:5]
    got = search("honor vendors")
    assert got and all(r[4] == "Honor vendors" for r in got), got[:5]
    # a ring slot: faction names and standings
    c.type_text(sb, "")
    c.eval("ns.Picker:Close()")
    open_picker(c, 11)
    sb = search_box(c)
    got = search("sha'tar")
    assert got and all(r[3] == "rep" and "Sha'tar" in r[4] for r in got), got
    got = search("exalted")
    assert got and all(r[3] == "rep" for r in got), got
    got = search("anwehu")
    assert got and ANGELISTA in [r[2] for r in got] and all(r[4] == "Anwehu" for r in got), got
    got = search("zzz no such thing")
    assert got == []
    assert c.eval("return T_textregion(DisasterZonePicker, 'No items match'):IsVisible()") is True
    # the item name still works for new-kind rows, and the search resets when the picker reopens
    name = c.eval("return ns.ItemDB:GetName(...)", ANGELISTA)
    got = search(name[:10])
    assert ANGELISTA in [r[2] for r in got], (name, got)
    c.eval("ns.Picker:Close()")
    open_picker(c, 11)
    assert c.eval("return T_template(DisasterZonePicker, 'SearchBoxTemplate')[1]:GetText()") == ""
    # ItemDB:Search itself matches group, specialisation, standing and faction
    n = c.eval("""
      local rows = ns.ItemDB:GetCandidates(5, { sources = { crafted = true, rep = true, badges = true, pvp = true },
                                               maxPhase = 5, faction = 'any' })
      local out = {}
      for _, q in ipairs({ 'armorsmith', 'blacksmithing', 'the aldor', 'revered', 'horde', 'honor vendors' }) do
        out[#out + 1] = #ns.ItemDB:Search(q, rows)
      end
      return unpack(out)""")
    assert all(x > 0 for x in n), n
    no_errors(w)


@case
def subtitles_and_source_texts_for_every_kind():
    w, c = setup()
    texts = {}
    for iid in (DIRGE, EMBRACE, LIGHTBEARER, MANA_BINDERS, ANGELISTA, GLAD_DREADWEAVE_HOOD, MARSHAL_SILK_CUFFS,
                MEDALLION_ALLIANCE):
        texts[iid] = (c.eval("return ns.ItemDB:GetSourceText(...)", iid),
                      c.eval("return ns.ItemDB:GetSourceText(..., true)", iid),
                      c.eval("return ns.ItemDB:GetSourceKind(...)", iid),
                      c.eval("return ns.ItemDB:GetPhase(...)", iid))
    assert texts[DIRGE] == ("Blacksmithing (365)", "Blacksmithing (365)", "craft", 1), texts[DIRGE]
    assert texts[EMBRACE] == ("Blacksmithing (375) \u00b7 Armorsmith", "Blacksmithing (375)", "craft", 2), texts[EMBRACE]
    assert texts[LIGHTBEARER] == ("The Aldor" + DASH + "Exalted", "The Aldor" + DASH + "Exalted", "rep", 1), texts[LIGHTBEARER]
    assert texts[MANA_BINDERS] == ("G'eras" + DASH + "50 badges",) * 2 + ("badge", 1), texts[MANA_BINDERS]
    assert texts[ANGELISTA] == ("Anwehu" + DASH + "60 badges",) * 2 + ("badge", 5), texts[ANGELISTA]
    assert texts[GLAD_DREADWEAVE_HOOD][2] == "pvp" and texts[GLAD_DREADWEAVE_HOOD][1].startswith("Arena Season 1"), \
        texts[GLAD_DREADWEAVE_HOOD]
    assert texts[GLAD_DREADWEAVE_HOOD][0].startswith("Arena Season 1 (Gladiator)")
    assert texts[MARSHAL_SILK_CUFFS][:2] == ("Arena Season 1 (Gladiator) (Alliance)", "Arena Season 1 (Alliance)")
    assert texts[MEDALLION_ALLIANCE][:2] == ("Honor vendors" + DASH + "8000 honor (Alliance)", "Honor vendors (Alliance)")
    # GetSources entries carry kind + the source details
    e = sources_of(c, EMBRACE)
    assert len(e) == 1 and e[0]["kind"] == "craft" and e[0]["skill"] == 375 and e[0]["spec"] == "Armorsmith" \
        and e[0]["phase"] == 2 and e[0]["reagentsNote"] == "2x Nether Vortex" and e[0]["groupName"] == "Blacksmithing", e
    e = sources_of(c, LIGHTBEARER)
    assert e[0]["kind"] == "rep" and e[0]["standing"] == "Exalted" and e[0]["factionID"] == 932, e
    e = sources_of(c, MANA_BINDERS)
    assert e[0]["kind"] == "badge" and e[0]["cost"] == 50 and e[0]["npcID"] == 18525, e
    e = sources_of(c, MEDALLION_ALLIANCE)
    assert e[0]["kind"] == "pvp" and e[0]["cost"] == "8000 honor" and e[0]["faction"] == "Alliance", e
    e = sources_of(c, MARSHAL_SILK_CUFFS)
    assert [x for x in e if x["kind"] == "pvp"][0]["season"] == 1, e
    # a raid item keeps its raid entry first with kind / phase / group
    drape = sources_of(c, 28766)
    assert drape[0]["kind"] == "raid" and drape[0]["groupName"] == "Karazhan" and drape[0]["phase"] == 1, drape
    # picker row subtitles: the row's own source (ItemDB:FormatSource), faction tagged
    open_picker(c, 5)
    c.dropdown_menu(phase_dd(c))
    c.menu_select("All phases")
    set_sources(c, crafted=True, badges=True, pvp=True)
    subs = c.eval_py(PICKER_SUBS)
    assert subs, "no rows"
    for iid, kind, sub, fmt in subs:
        # DisasterZone 0.5: class-restricted items (PvP set pieces, ...) also name their classes after the source
        assert sub and (sub == fmt or sub.startswith(fmt + "  ·  ")), (iid, kind, sub, fmt)
    by = {s[0]: s[2] for s in subs}
    assert by[BULWARK_ANCIENT] == "Blacksmithing (375) \u00b7 Armorsmith", by[BULWARK_ANCIENT]
    assert by.get(BULWARK_KINGS) == "Blacksmithing (375) \u00b7 Armorsmith", by.get(BULWARK_KINGS)
    assert any(s[1] == "badge" and DASH in s[2] and s[2].endswith(" badges") for s in subs)
    # the tooltip adds the reagents note
    c.eval("""
      local id = ...
      for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do
        local d = rawget(r, '__cdlData')
        if d and d.itemID == id then r:GetScript('OnEnter')(r) end
      end""", BULWARK_ANCIENT)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    assert "Needs 2x Nether Vortex" in lines and "Blacksmithing (375) \u00b7 Armorsmith" in lines, lines
    # the ring slot: rep subtitles
    c.eval("ns.Picker:Close()")
    open_picker(c, 2)
    set_sources(c, rep=True)
    subs = c.eval_py(PICKER_SUBS)
    assert subs and all(s[1] == "rep" and re.search(DASH + "(Friendly|Honored|Revered|Exalted)$", s[2]) for s in subs), subs[:4]
    no_errors(w)


@case
def phase_filter_applies_to_every_source():
    w, c = setup()
    open_picker(c, 5)
    set_sources(c, crafted=True, badges=True, pvp=True, rep=True)
    ph_dd = phase_dd(c)

    def phases():
        return {r[3]: sorted({x[7] for x in items(c) if x[3] == r[3]}) for r in items(c)}

    got = items(c)                                    # default: up to P1 (the guild phase)
    assert got and all(r[7] == 1 for r in got), sorted({(r[3], r[7]) for r in got})
    assert BULWARK_ANCIENT not in [r[2] for r in got] and BULWARK_KINGS in [r[2] for r in got]
    c.dropdown_menu(ph_dd)
    c.menu_select("All phases")
    allp = items(c)
    assert BULWARK_ANCIENT in [r[2] for r in allp] and len(allp) > len(got)
    assert max(r[7] for r in allp if r[3] == "pvp") >= 2
    # P2 view: "Only P2" lists only phase-2 items of every kind
    c.eval("ns.Picker:Close()")
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    open_picker(c, 5)
    c.dropdown_menu(phase_dd(c))
    c.menu_select("Only P2")
    only2 = items(c)
    assert only2 and all(r[7] == 2 for r in only2), sorted({(r[3], r[7]) for r in only2})
    assert BULWARK_ANCIENT in [r[2] for r in only2] and {"craft", "pvp"} <= {r[3] for r in only2}
    c.dropdown_menu(phase_dd(c))
    c.menu_select("Up to P2")
    upto2 = items(c)
    assert all(r[7] <= 2 for r in upto2) and len(upto2) > len(only2)
    # ItemDB: the Anwehu (P5) ring only from P5 on
    assert ANGELISTA not in [r[0] for r in cands(c, 11, sources={"badges": True}, maxPhase=4)]
    assert ANGELISTA in [r[0] for r in cands(c, 11, sources={"badges": True}, maxPhase=5)]
    assert ANGELISTA in [r[0] for r in cands(c, 11, sources={"badges": True}, phase=5)]
    assert [r for r in cands(c, 11, sources={"badges": True}, phase=5) if r[5] != 5] == []
    no_errors(w)


@case
def items_without_a_phase_count_as_p1_and_bad_data_is_skipped():
    w, c = solo("Alice", tick=2)
    w.define_item(190123, "Test Badge Helm", 4, "INVTYPE_HEAD", 4, 4, ilvl=115)
    w.define_item(190124, "Test Rep Helm", 4, "INVTYPE_HEAD", 4, 4, ilvl=115)
    # injected before the lazy index is built (the first use of a new source kind)
    assert c.eval("return #ns.ItemDB:GetCandidates(1, { maxPhase = 1 })") > 0     # raids only: no build yet
    c.eval("""
      table.insert(ns.Data.Badges[1].items, { id = 190123, cost = 10 })             -- no phase
      table.insert(ns.Data.Badges[1].items, { id = 190123, cost = 99, phase = 4 })  -- duplicate in the group
      table.insert(ns.Data.Badges[1].items, { id = 'x' })
      table.insert(ns.Data.Badges[1].items, { id = -5 })
      table.insert(ns.Data.Badges[1].items, 'junk')
      table.insert(ns.Data.Reputation, { key = 'TestRep', name = 'Test Rep', items = { { id = 190124, standing = 'Honored' } } })
      table.insert(ns.Data.Reputation, 'junk')
      table.insert(ns.Data.Reputation, { key = 'NoItems' })""")
    only1 = [r[0] for r in cands(c, 1, sources={"badges": True, "rep": True}, phase=1)]
    assert 190123 in only1 and 190124 in only1, only1
    assert 190123 not in [r[0] for r in cands(c, 1, sources={"badges": True}, phase=4)]
    e = sources_of(c, 190123)
    assert len(e) == 1 and e[0]["cost"] == 10 and e[0]["phase"] == 1, e
    assert c.eval("return ns.ItemDB:GetSourceText(190124)") == "Test Rep" + DASH + "Honored"
    assert c.eval("return ns.ItemDB:GetPhase(190124)") == 1
    no_errors(w)


@case
def get_sources_scopes_and_drops_only_auto_ledger():
    w, c = solo("Alice", tick=2)
    kinds = [e["kind"] for e in sources_of(c, GLAD_DREADWEAVE_HOOD)]
    assert "pvp" in kinds, kinds
    assert [e["kind"] for e in sources_of(c, EMBRACE, "drops")] == []
    assert [e["kind"] for e in sources_of(c, EMBRACE, "craft")] == ["craft"]
    assert [e["kind"] for e in sources_of(c, EMBRACE, "crafted")] == ["craft"]
    assert [e["kind"] for e in sources_of(c, LIGHTBEARER, "reputation")] == ["rep"]
    assert [e["kind"] for e in sources_of(c, MANA_BINDERS, "badges")] == ["badge"]
    assert [e["kind"] for e in sources_of(c, MEDALLION_ALLIANCE, "pvp")] == ["pvp"]
    assert sources_of(c, MEDALLION_ALLIANCE, "raids") == []
    assert [e["kind"] for e in sources_of(c, 28766, "drops")] == ["raid"]
    assert c.eval("return #ns.ItemDB:GetSources(28766, 'nonsense')") >= 1          # unknown scope = all
    assert c.eval("return ns.ItemDB:GetSourceText(999999)") is None
    assert c.eval("return ns.ItemDB:GetSourceKind(999999)") is None
    assert c.eval("return ns.ItemDB:GetSourceKind('x')") is None
    # the auto-ledger keeps its "boss loot" meaning: a crafted epic handed out in a raid is not recorded
    w2 = World()
    gm = Client(w2, "Gm", guild_rank=0, class_file="PALADIN")
    bob = Client(w2, "Bob", guild_rank=3, class_file="WARRIOR")
    for x in (gm, bob):
        x.load_addon()
    w2.tick(3)
    w2.make_raid([gm, bob], master_looter=gm, leader=gm)
    w2.tick(2)
    w2.enter_instance("Karazhan", 532)
    w2.tick(1)
    assert gm.eval("return ns.Guild:AmICouncil(true)") is True
    n0 = gm.eval("local n = 0 for _ in pairs(ns.db.ledger) do n = n + 1 end return n")
    w2.define_item(EMBRACE, "Embrace of the Twisting Nether", 4, "INVTYPE_CHEST", 4, 4, ilvl=141)
    w2.broadcast_loot_received(bob, EMBRACE)
    w2.tick(2)
    n1 = gm.eval("local n = 0 for _ in pairs(ns.db.ledger) do n = n + 1 end return n")
    assert n1 == n0, "crafted item recorded as boss loot"
    w2.broadcast_loot_received(bob, 28766)
    w2.tick(2)
    n2 = gm.eval("local n = 0 for _ in pairs(ns.db.ledger) do n = n + 1 end return n")
    assert n2 == n0 + 1, (n0, n1, n2)
    no_errors(w)
    no_errors(w2)


@case
def all_sources_on_one_slot_is_fast():
    w, c = solo("Alice", tick=2)
    f = {"sources": ALL_ON, "maxPhase": 5}
    t0 = time.perf_counter()
    n_first = c.eval("local s, f = ...; return #ns.ItemDB:GetCandidates(s, f)", 5, f)
    first_ms = (time.perf_counter() - t0) * 1000
    worst = 0.0
    counts = {}
    for sid in range(1, 18):
        t0 = time.perf_counter()
        n = c.eval("local s, f = ...; local t for i = 1, 10 do t = ns.ItemDB:GetCandidates(s, f) end return #t", sid, f)
        ms = (time.perf_counter() - t0) * 1000 / 10
        worst = max(worst, ms)
        counts[sid] = n
    fc = dict(f, **{"class": "PALADIN", "usableOnly": True})
    t0 = time.perf_counter()
    c.eval("local f = ...; for s = 1, 17 do ns.ItemDB:GetCandidates(s, f) end", fc)
    filtered_ms = (time.perf_counter() - t0) * 1000 / 17
    print("   first (index build) %.1f ms (%d rows), worst slot %.2f ms/call, class-filtered %.2f ms/slot, rows %r"
          % (first_ms, n_first, worst, filtered_ms, counts))
    assert n_first > 100
    # generous bounds (parallel suite runs share the CPU): the core measured ~13 ms build, ~0.5 ms per call
    assert first_ms < 400, first_ms
    assert worst < 15, worst
    assert filtered_ms < 30, filtered_ms
    # the picker with every source ticked opens and searches in reasonable time
    install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    c.eval("ns.Picker:SetSourceEnabled('crafted', true); ns.Picker:SetSourceEnabled('rep', true); "
           "ns.Picker:SetSourceEnabled('badges', true); ns.Picker:SetSourceEnabled('pvp', true)")
    t0 = time.perf_counter()
    open_picker(c, 5)
    open_ms = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    c.type_text(search_box(c), "season")
    w.tick(0.3)
    search_ms = (time.perf_counter() - t0) * 1000
    print("   picker open %.0f ms, search %.0f ms (mock UI)" % (open_ms, search_ms))
    assert open_ms < 3000 and search_ms < 3000, (open_ms, search_ms)
    no_errors(w)


if __name__ == "__main__":
    run_all()
