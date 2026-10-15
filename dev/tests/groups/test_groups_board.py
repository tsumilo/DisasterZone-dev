"""Groups, step 2 (UI/DungeonsTab.lua + UI/GroupsCard.lua): the Groups board.

Covers: the tabs filter the board by kind and count each kind, an empty kind says so; in a section the groups that
want me come first and the ones I can't join last, and the section says how many want me; a card opens in place (one at
a time; seats up to 10 players, raid frames above, my place marked) and closes again; Join on an opened card asks the
leader; the "I'm up for" chips switch the kinds I'm up for; a raid group that needs me pings me with the pop-up.

Run: luaenv\\Scripts\\python.exe tests\\groups\\test_groups_board.py [-k name]   (from dev)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50


def guild(names, tick=HELLO):
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def K(cl):
    return cl.full_name


def roles(cl, *on):
    for r in on:
        cl.eval("ns.DungeonRuns:SetMyRole(...)", r, True)
    for r in ("tank", "healer", "dps"):
        if r not in on:
            cl.eval("ns.DungeonRuns:SetMyRole(...)", r, False)


def list_group(cl, **opts):
    rid = cl.eval_py("""
      local o = ...
      local t = {}
      for k, v in pairs(o) do t[k] = v end
      local r, why = ns.DungeonRuns:List(t)
      return r and r.id or why""", opts)
    assert isinstance(rid, str) and ":" in rid, rid
    return rid


def board(cl):
    """The cards on cl's board, top to bottom: { id, h (height), open }."""
    return cl.eval_py("""
      local out = {}
      for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do
        if c:IsShown() then
          local _, _, _, _, y = c:GetPoint(1)
          out[#out + 1] = { id = c.runId, y = -(y or 0), h = c:GetHeight(),
                            open = (c.open and c.open:IsShown()) or false }
        end
      end
      table.sort(out, function(a, b) return a.y < b.y end)
      for _, e in ipairs(out) do e.y = nil end
      return out""") or []


def headers(cl):
    return cl.eval_py("""
      local out = {}
      for _, h in ipairs(ns.DungeonsUI:GetPanel().headers) do
        if h:IsShown() then out[#out + 1] = (h.title:GetText() or '') .. '|' .. (h.count:GetText() or '') end
      end
      return out""") or []


def strip_codes(s):
    import re
    return re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "")


def open_tab(cl):
    cl.eval("ns.MainFrame:Open('dungeons')")


# ------------------------------------------------------------------------------------------------------------------
@case
def the_tabs_filter_by_kind_and_count_each_kind():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval("ns.Demo:SetEnabled(true)")
    w.tick(1)
    open_tab(g)
    w.tick(1)
    labels = g.eval_py("local out = {}; for _, b in ipairs(ns.DungeonsUI:GetPanel().tabsRow.tabs) do "
                       "out[#out + 1] = b:GetText() end; return out")
    assert [strip_codes(x) for x in labels] == ["All  8", "Dungeons  4", "Raids  2", "Quests  0", "PvP  2"], labels
    g.eval("ns.DungeonsUI:SetTab('raid')")
    assert sorted(x["id"] for x in board(g)) == ["demo-r1", "demo-r2"], board(g)
    g.eval("ns.DungeonsUI:SetTab('pvp')")
    assert sorted(x["id"] for x in board(g)) == ["demo-p1", "demo-p2"], board(g)
    # a kind with nothing listed says so
    g.eval("ns.DungeonsUI:SetTab('quest')")
    assert board(g) == []
    assert g.eval_py("local e = ns.DungeonsUI:GetPanel().empty; return e:IsShown() and e.title:GetText()") == \
        "No quest groups listed right now."
    g.eval("ns.DungeonsUI:SetTab('all')")
    assert len(board(g)) == 8
    w.assert_no_errors()


@case
def the_groups_that_want_me_come_first_and_the_blocked_last():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE"), ("Dora", "ROGUE"), ("Evie", "HUNTER")])
    g, b, cara, d, e = c["Gina"], c["Bert"], c["Cara"], c["Dora"], c["Evie"]
    roles(cara, "dps")
    cara.eval("__MOCK.factions[1011] = 5")       # (Lower City honored: no heroic Shadow Labyrinth for Cara)
    slab = list_group(d, d="ShadowLabyrinth", h=True, role="dps")
    w.tick(1)
    quest = list_group(e, k="quest", a=[9977], n=3, role="dps", w={"tank": 1, "healer": 1, "dps": 1})
    w.tick(1)
    kara = list_group(b, k="raid", a=["Karazhan"], role="tank")
    w.tick(1)
    arena = list_group(g, k="pvp", a=["arena3"], role="healer")
    w.tick(3)
    open_tab(cara)
    w.tick(1)
    order = [x["id"] for x in board(cara)]
    # wanting me first (newest first among them), then the quest group (no place for a mage), the blocked heroic last
    assert order == [arena, kara, quest, slab], (order, [arena, kara, quest, slab])
    hs = [strip_codes(x) for x in headers(cara)]
    assert hs == ["Now|2 want you"], hs
    w.assert_no_errors()


@case
def a_card_opens_in_place_one_at_a_time():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval("ns.Demo:SetEnabled(true)")
    roles(g, "tank", "healer")
    w.tick(1)
    open_tab(g)
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('raid')")
    closed = {x["id"]: x["h"] for x in board(g)}
    assert closed == {"demo-r1": 72, "demo-r2": 72}, closed
    # Karazhan opens: 10 seats, the healer place that wants me shows me; the card grows
    g.eval("ns.DungeonsUI:OpenCard('demo-r1')")
    cards = {x["id"]: x for x in board(g)}
    assert cards["demo-r1"]["open"] is True and cards["demo-r1"]["h"] > 200, cards
    seats = g.eval_py("""
      for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do
        if c.runId == 'demo-r1' then
          local out = {}
          for _, s in ipairs(c.open.seats) do if s:IsShown() then out[#out + 1] = s.name:GetText() end end
          return out
        end
      end""")
    names = [strip_codes(x) for x in seats]
    assert len(names) == 10 and names.count("You") == 1 and names.count("open") == 2, names
    # Gruul + Magtheridon opens instead (one at a time): 25 raid frame cells
    g.eval("ns.DungeonsUI:OpenCard('demo-r2')")
    cards = {x["id"]: x for x in board(g)}
    assert cards["demo-r1"]["open"] is False and cards["demo-r1"]["h"] == 72 and cards["demo-r2"]["open"] is True
    cells = g.eval_py("""
      for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do
        if c.runId == 'demo-r2' then
          local n, you = 0, 0
          for _, f in ipairs(c.open.cells) do
            if f:IsShown() then
              n = n + 1
              if (f.name:GetText() or ''):find('You') then you = you + 1 end
            end
          end
          return { n, you }
        end
      end""")
    assert cells == [25, 1], cells
    # a click on the opened card closes it
    g.eval("for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do "
           "if c:IsShown() and c.runId == 'demo-r2' then c.onToggle() break end end")
    assert all(x["open"] is False for x in board(g)) and g.eval_py("return ns.DungeonsUI:GetOpenCard()") is None
    w.assert_no_errors()


@case
def join_on_an_opened_card_asks_the_leader():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE")])
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    open_tab(b)
    w.tick(1)
    b.eval("ns.DungeonsUI:OpenCard(...)", rid)
    btn = b.eval_py("for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do if c.runId == ... then "
                    "return c.open.join:IsShown() and c.open.join:GetText() end end", rid)
    assert btn == "Join as tank", btn
    # (the head's Join gives way while the card is open)
    assert b.eval_py("for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do if c.runId == ... then "
                     "return c.btn:IsShown() end end", rid) is False
    b.eval("for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do if c.runId == ... then c.open.join:Click() end end", rid)
    w.tick(2)
    req = g.eval_py("local r = ns.DungeonRuns:GetRequests(...)[1]; return r and { key = r.key, r = r.r }", rid)
    assert req == {"key": K(b), "r": "tank"}, req
    assert b.eval_py("for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do if c.runId == ... then "
                     "return c.open.join:GetText() end end", rid) == "Asked"
    w.assert_no_errors()


@case
def the_up_for_chips_switch_the_kinds():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g = c["Gina"]
    open_tab(g)
    w.tick(1)
    chips = g.eval_py("local out = {}; for _, ch in ipairs(ns.DungeonsUI:GetPanel().top.kinds) do "
                      "out[#out + 1] = { k = ch.kindKey, on = ch.on } end; return out")
    assert chips == [{"k": "dungeon", "on": True}, {"k": "raid", "on": True}, {"k": "quest", "on": False},
                     {"k": "pvp", "on": False}], chips
    g.eval("ns.DungeonsUI:GetPanel().top.kinds[4]:Click()")
    w.tick(1)
    assert g.eval_py("return ns.DungeonRuns:GetMyKinds()") == {"dungeon": True, "raid": True, "pvp": True}
    assert g.eval_py("return ns.DungeonsUI:GetPanel().top.kinds[4].on") is True
    g.eval("ns.DungeonsUI:GetPanel().top.kinds[1]:Click()")
    w.tick(1)
    assert g.eval_py("return ns.DungeonRuns:GetMyKinds()") == {"raid": True, "pvp": True}
    w.assert_no_errors()


@case
def a_raid_group_that_needs_me_pings_me():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE")])
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    b.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(3)
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    t = b.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() and { run = t.run, "
                  "title = t.t2 and t.t2:GetText() }")
    assert t and t["run"] == rid, t
    assert "needs a tank" in strip_codes(t["title"]), t
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
