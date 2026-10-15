"""Atlas costs and the currency bar (Core/Currency.lua, UI/Atlas.lua, ns.Data.AtlasCosts).

Covers: an item's cost at the row's right with the currencies' icons, red while I hold less and white once I hold
enough; the tooltip's Cost block (what I lack / have, some in the bank); the currency bar (Honor, Arena Points and
Badges always, then what the list shown pays with) and how hovering a row lights its currencies with what buying it
needs or leaves; a set page's total for the pieces I don't own; where costs come from (a vendor I opened, AtlasLoot's
own scans, the shipped table, a season's other pieces of the same slot) and reading a vendor (honor / arena points by
their icon or name, items by their link, money only for items the Atlas lists, nothing for stacks or costs not loaded).

Run: luaenv\\Scripts\\python.exe tests\\atlas\\test_atlas_costs.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, solo, no_errors, install_helpers, strip_codes, tt_lines  # noqa: E402

RED = "|cffff5a4f"
WHITE = "|cffe8e8e8"
BADGE = 29434
BADGE_LINK = "|cffa335ee|Hitem:29434::::::::70:::::|h[Badge of Justice]|h|r"
S3_RET = {33749: 1550, 33750: 930, 33751: 1550, 33752: 1550, 33753: 1245}   # Vengeful Gladiator's Vindication

LUA = r"""
function T_atlas() return ns.MainFrame:GetPanel("atlas") end
function T_bar()
  local bar = T_atlas().currencyBar
  local out = { chips = {}, rule = bar.rule:IsShown() and 1 or 0 }
  for _, ch in ipairs(bar.chips) do
    if ch:IsShown() then out.chips[#out.chips + 1] = { ch.key, ch.amount:GetText() or "", ch.state or "" } end
  end
  return out
end
function T_row(id)
  local _, _, list = ns.AtlasUI:GetLists()
  for _, r in ipairs(list.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == "item" and d.id == id and r:IsShown() then return r end
  end
end
-- the item list's header rows: { text, cost text }
function T_headers()
  local _, _, list = ns.AtlasUI:GetLists()
  local o = {}
  for _, d in ipairs(list:GetData()) do
    if d.type == "header" then o[#o + 1] = { d.text, d.cost or "" } end
  end
  return o
end
function T_headrow(text)
  local _, _, list = ns.AtlasUI:GetLists()
  for _, r in ipairs(list.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == "header" and d.text == text and r:IsShown() then return r end
  end
end
function T_mark(id)
  local r = T_row(id)
  return r and r:StatusText() or nil
end
function T_cost(id)
  local parts, from = ns.Currency:GetCost(id)
  if not parts then return nil end
  local o = {}
  for i, p in ipairs(parts) do o[i] = p.key .. ":" .. p.n end
  return { table.concat(o, ","), from }
end
-- the first item of a source whose shipped cost matches a Lua pattern: { pageKey, id, cost }
function T_find(cat, src, pattern)
  for _, p in ipairs(ns.Atlas:GetSource(cat, src).pages) do
    for _, id in ipairs(p.items) do
      local c = ns.Data.AtlasCosts[id]
      if c and c:match(pattern) then return { p.key, id, c } end
    end
  end
end
"""


def setup(**kw):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=3, tick=4, council=[], **kw)
    install_helpers(c)
    c.eval(LUA)
    c.eval("ns.MainFrame:Open('atlas')")
    w.tick(0.3)
    return w, c


def bar(c):
    b = c.eval_py("return T_bar()")
    return {"rule": b["rule"],
            "chips": [(ch[0], strip_codes(ch[1]), ch[2]) for ch in (b["chips"] or [])]}


def honor_item(c):
    """A PvP Honor page item that costs honor only (shipped): (pageKey, id, amount)."""
    page, iid, cost = c.eval_py("return T_find('pvp', 'Honor', '^c1901:%d+$')")
    return page, iid, int(cost.split(":")[1])


# ------------------------------------------------------------------------------------------------------------------
@case
def row_cost_is_red_until_i_hold_enough():
    w, c = setup()
    page, iid, amount = honor_item(c)
    c.eval("__MOCK.set_currency(1901, ...)", amount - 1)
    c.eval("ns.AtlasUI:Select('pvp', 'Honor', ...)", page)
    w.tick(0.5)
    mark = c.eval("return T_mark(...)", iid)
    assert mark and RED + str(amount) in mark and "|T" in mark, mark
    # the honor icon is the faction's PvP-Currency texture, cut like Blizzard's merchant does
    assert "136998" in mark and ":64:64:0:40:0:40|t" in mark, mark
    c.eval("__MOCK.set_currency(1901, ...)", amount)
    w.tick(0.6)
    mark = c.eval("return T_mark(...)", iid)
    assert WHITE + str(amount) in mark and RED not in mark, mark
    no_errors(w)


@case
def tooltip_says_what_i_lack_or_have():
    w, c = setup()
    page, iid, amount = honor_item(c)
    c.eval("__MOCK.set_currency(1901, 100)")
    c.eval("ns.AtlasUI:Select('pvp', 'Honor', ...)", page)
    w.tick(0.5)
    c.hover(c.eval("return T_row(...)", iid))
    lines = [(strip_codes(l), strip_codes(r)) for l, r in tt_lines(c)]
    assert ("Cost", "") in lines, lines
    row = next(l for l in lines if "Honor Points" in l[0])
    assert row[0].endswith("%d Honor Points" % amount) and row[1] == "%d more needed" % (amount - 100), row
    c.eval("__MOCK.set_currency(1901, ...)", amount + 50)
    w.tick(0.6)
    c.hover(c.eval("return T_row(...)", iid))
    lines = [(strip_codes(l), strip_codes(r)) for l, r in tt_lines(c)]
    row = next(l for l in lines if "Honor Points" in l[0])
    assert row[1] == "You have %d" % (amount + 50), row
    no_errors(w)


@case
def bar_pins_honor_arena_badges_then_what_the_page_pays_with():
    w, c = setup()
    c.eval("__MOCK.set_currency(1901, 12345); __MOCK.set_currency(1900, 678)")
    c.eval("__MOCK.give_item(29434, 42)")
    w.tick(0.6)
    b = bar(c)
    keys = [k for k, _, _ in b["chips"]]
    assert keys[:3] == ["c1901", "c1900", "29434"], keys
    assert [a for _, a, _ in b["chips"][:3]] == ["12345", "678", "42"], b["chips"]
    # a page paying with something else: its currency after the rule
    found = c.eval_py("""for _, cat in ipairs(ns.Atlas:GetCategories()) do
        for _, s in ipairs(cat.sources) do for _, p in ipairs(s.pages) do for _, id in ipairs(p.items) do
          local cost = ns.Data.AtlasCosts[id]
          local other = cost and cost:match('(%d+):%d+')
          if other and other ~= '29434' then return { cat.key, s.key, p.key, other } end
        end end end end""")
    assert found, "no page paying with an item currency"
    c.eval("ns.AtlasUI:Select(...)", found[0], found[1], found[2])
    w.tick(0.4)
    b = bar(c)
    keys = [k for k, _, _ in b["chips"]]
    assert keys[:3] == ["c1901", "c1900", "29434"] and found[3] in keys[3:] and b["rule"] == 1, (keys, found)
    # a raid page pays with nothing: the pinned three alone
    c.eval("ns.AtlasUI:Select(ns.Atlas:DefaultSource())")
    w.tick(0.4)
    b = bar(c)
    assert [k for k, _, _ in b["chips"]] == ["c1901", "c1900", "29434"] and b["rule"] == 0, b
    no_errors(w)


@case
def hovering_a_row_lights_its_currencies():
    w, c = setup()
    page, iid, amount = honor_item(c)
    c.eval("__MOCK.set_currency(1901, ...)", amount - 25)
    c.eval("ns.AtlasUI:Select('pvp', 'Honor', ...)", page)
    w.tick(0.5)
    row = c.eval("return T_row(...)", iid)
    c.hover(row)
    b = bar(c)
    assert ("c1901", str(amount - 25), "short") in b["chips"], b["chips"]
    c.leave(row)
    b = bar(c)
    assert all(s == "" for _, _, s in b["chips"]), b
    c.eval("__MOCK.set_currency(1901, ...)", amount + 300)
    w.tick(0.6)
    c.hover(c.eval("return T_row(...)", iid))
    b = bar(c)
    assert ("c1901", str(amount + 300), "ok") in b["chips"], b["chips"]
    no_errors(w)


@case
def badges_in_the_bank_count_and_say_so():
    w, c = setup()
    page, iid, cost = c.eval_py("return T_find('vendors', 'BadgeofJustice', '^29434:%d+$')")
    need = int(cost.split(":")[1])
    c.eval("local n = ...; __MOCK.set_bags({ { -1, 1, 29434, n } }, true)", need + 5)
    w.tick(0.6)
    c.eval("ns.AtlasUI:Select('vendors', 'BadgeofJustice', ...)", page)
    w.tick(0.4)
    assert WHITE + str(need) in c.eval("return T_mark(...)", iid)
    c.hover(c.eval("return T_row(...)", iid))
    lines = [(strip_codes(l), strip_codes(r)) for l, r in tt_lines(c)]
    assert any(r == "Some is in your bank" for _, r in lines), lines
    no_errors(w)


def set_headers(c):
    """{header text: its cost text (codes stripped, spaces squeezed) or ''} of the item list."""
    out = {}
    for h in c.eval_py("return T_headers()") or []:
        out[h[0]] = " ".join(strip_codes(h[1]).split())
    return out


@case
def set_headers_total_the_pieces_i_dont_own():
    w, c = setup()
    # the Sets source lists a class per page, a header per set; my class's page opens first
    c.eval("ns.AtlasUI:Select('sets', 'ArenaS3', 'Paladin')")
    w.tick(0.4)
    heads = set_headers(c)
    ret = next(k for k in heads if "Vengeful Gladiator's Vindication" in k)
    total = sum(S3_RET.values())
    assert heads[ret] == "Set %d" % total, heads
    # the drawn header row shows it at its right (the amounts alone when the name needs the room), the name in full
    row = c.eval("return T_headrow(...)", ret)
    assert row is not None
    shown = " ".join(strip_codes(c.eval("local r = ...; return r.headCost:GetText()", row)).split())
    assert shown in ("Set %d" % total, "%d" % total), shown
    assert c.eval("local r = ...; return r.headCost:IsShown()", row) is True
    assert strip_codes(c.eval("local r = ...; return r.header:GetText()", row)) == ret
    # a piece I own: the rest
    c.eval("local own = ...; local old = ns.BiS.IsObtained; ns.BiS.IsObtained = function(self, id) return id == own or old(self, id) end", 33751)
    c.eval("ns.AtlasUI:RefreshItems()")
    assert set_headers(c)[ret] == "Still to buy %d" % (total - S3_RET[33751]), set_headers(c)
    # a set with a piece nobody priced: no total
    c.eval("local A = ns.Currency.GetCost; ns.Currency.GetCost = function(self, id) if id == 33749 then return nil end return A(self, id) end")
    c.eval("ns.AtlasUI:RefreshItems()")
    assert set_headers(c)[ret] == "", set_headers(c)
    no_errors(w)


@case
def other_classes_pieces_take_the_seasons_price_for_their_slot():
    w, c = setup()
    got = c.eval_py("""local o = {}
        for _, cat in ipairs({ 'sets', 'pvp' }) do
          for _, p in ipairs(ns.Atlas:GetSource(cat, 'ArenaS3').pages) do
            for _, id in ipairs(p.items) do
              local r = T_cost(id)
              if r and r[2] == 'season' then o[#o + 1] = { id, r[1], (select(4, C_Item.GetItemInfoInstant(id))) } end
            end
          end
        end
        return o""") or []
    assert got, "no Season 3 piece priced from its slot"
    iid, cost, slot = got[0]
    # it is the price of a priced Season 3 piece for that slot
    peers = c.eval_py("""local slot, cost = ...
        local o = {}
        for _, cat in ipairs({ 'sets', 'pvp' }) do
          for _, p in ipairs(ns.Atlas:GetSource(cat, 'ArenaS3').pages) do
            for _, id in ipairs(p.items) do
              local r = T_cost(id)
              local loc = select(4, C_Item.GetItemInfoInstant(id))
              if loc == 'INVTYPE_ROBE' then loc = 'INVTYPE_CHEST' end
              if r and r[2] ~= 'season' and loc == slot then o[#o + 1] = { id, r[1] } end
            end
          end
        end
        return o""", "INVTYPE_CHEST" if slot == "INVTYPE_ROBE" else slot, cost) or []
    assert peers and all(p[1] == cost for p in peers), (iid, cost, slot, peers)
    # a vendor asking another price for one of them: the slot's pieces disagree, no guess any more
    c.eval("local id = ...; ns.db.prices[id] = 'c1900:1|0'; ns.Currency:Invalidate()", peers[0][0])
    assert c.eval_py("return T_cost(...)", iid) is None
    # weapons are never guessed (a wand and a crossbow share a slot)
    weapons = c.eval_py("""local o = {}
        for _, p in ipairs(ns.Atlas:GetSource('pvp', 'ArenaS3').pages) do
          for _, id in ipairs(p.items) do
            local r = T_cost(id)
            if r and r[2] == 'season' and select(6, C_Item.GetItemInfoInstant(id)) == 2 then o[#o + 1] = id end
          end
        end
        return o""") or []
    assert weapons == [], weapons
    no_errors(w)


@case
def vendor_prices_are_learned_and_win():
    w, c = setup()
    page, iid, amount = honor_item(c)
    arena_id = 33751
    plain_gold = c.eval_py("for id, cost in pairs(ns.Data.AtlasCosts) do if cost:match('^g:%d+$') then return id end end")
    food = 27854   # Smoked Talbuk Venison: not in the Atlas
    assert c.eval("return ns.Data.AtlasNames[...] == nil", food)
    c.eval("""local honor, arena, gold, food, link = ...
        __MOCK.open_merchant({
          { id = honor, costs = { { 136998, 4321, nil, 'Honor Points' } } },
          { id = arena, costs = { { 136729, 999, nil, 'Arena Points' } } },
          { id = 32083, costs = { { 133633, 50, link, nil } } },
          { id = gold, price = 123456 },
          { id = food, price = 500 },
          { id = 32084, stack = 5, costs = { { 133633, 7, link, nil } } },
          { id = 32085, costs = { { nil, nil, nil, nil } } },
        })""", iid, arena_id, plain_gold, food, BADGE_LINK)
    w.tick(0.6)
    prices = c.eval_py("local o = {} for k, v in pairs(ns.db.prices) do o[k] = v:match('^[^|]+') end return o")
    assert prices.get(iid) == "c1901:4321" and prices.get(arena_id) == "c1900:999", prices
    assert prices.get(32083) == "29434:50" and prices.get(plain_gold) == "g:123456", prices
    assert food not in prices and 32084 not in prices and 32085 not in prices, prices
    assert c.eval_py("return T_cost(...)", iid) == ["c1901:4321", "vendor"]
    # the row shows the vendor's price
    c.eval("ns.AtlasUI:Select('pvp', 'Honor', ...)", page)
    w.tick(0.4)
    assert "4321" in strip_codes(c.eval("return T_mark(...)", iid))
    no_errors(w)


@case
def atlasloot_scans_are_read_when_installed():
    w, c = setup()
    page, iid, amount = honor_item(c)
    c.eval("""local a, b = ...
        AtlasLoot = { dbGlobal = { VendorPrice = { [a] = 'honorA:123:pvpEye:4', [b] = 'mystery:5' } } }
        ns.Currency:Invalidate()""", iid, BADGE + 1)
    assert c.eval_py("return T_cost(...)", iid) == ["c1901:123,29024:4", "atlasloot"]
    assert c.eval_py("return T_cost(...)", BADGE + 1) is None
    assert c.eval_py("return ns.Currency:FromAtlasLoot('arena:1875')") == "c1900:1875"
    # what a vendor asked me wins over AtlasLoot's
    c.eval("local id = ...; ns.db.prices[id] = 'c1901:77|0'", iid)
    assert c.eval_py("return T_cost(...)", iid) == ["c1901:77", "vendor"]
    no_errors(w)


@case
def shipped_costs_are_well_formed():
    w, c = setup()
    bad = c.eval_py("""local o = {}
        for id, cost in pairs(ns.Data.AtlasCosts) do
          if not ns.Currency:Parse(cost) or not ns.Data.AtlasNames[id] then o[#o + 1] = id end
        end
        return o""") or []
    assert bad == [], bad[:10]
    n = c.eval("local n = 0 for _ in pairs(ns.Data.AtlasCosts) do n = n + 1 end return n")
    assert n > 500, n
    # the Sunmote upgrades cost a Sunmote
    up = c.eval_py("for _, u in pairs(ns.Data.Upgrades) do return u end")
    assert c.eval_py("return T_cost(...)", up) == ["34664:1", "shipped"]
    assert c.eval_py("return ns.Currency:Parse('c1901:0')") is None
    assert c.eval_py("return ns.Currency:Parse('x:5')") is None
    no_errors(w)


if __name__ == "__main__":
    sys.exit(run_all())
