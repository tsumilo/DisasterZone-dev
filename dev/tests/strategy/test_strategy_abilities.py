"""ADDENDUM K: boss abilities and conditions in interrupt tables, on the real addon.

Covers: the ability lists generated from DBM (Council: Circle of Healing marked interrupt with its 14 s cooldown,
Divine Wrath / Empowered Smite added, the council's buffs), only the chosen abilities count as casts to kick (Empowered
Smite doesn't flash anyone), DBM's cooldown as the first rhythm, a physical immunity (Blessing of Protection) sending
the turn from the rogue to the shaman automatically and a spell immunity the other way, a row "only when the boss has
Blessing of Protection", a row "only when the boss is below 30%", the editor's Abilities / Only when menus, and the
practice run showing an immunity.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_abilities.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import open_full_starter  # noqa: E402
from test_strategy_live import (raid, see, engage, cleu, lines, rot_state, rot_item, BOSS, K)  # noqa: E402
from _common import World, Client, case, run_all, strip_codes, menu_texts  # noqa: E402
import _common  # noqa: E402

del _common._CASES[:]       # the live suite's cases were registered by the import: run only this file's


def set_rows(bob, sid, conds):
    """Sets Malande interrupts rows' conditions ({row: "a:<id>" | "hp:<pct>"}) in one save."""
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    for row, w in conds.items():
        bob.eval("local row, w = ...; ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi').d[row][3].w = w",
                 row, w)
    bob.eval("ns.StrategyBoard:Save()")


def pick(cl):
    s = rot_state(cl)
    return s["pick"], s["how"]


# ------------------------------------------------------------------------------------------------------------------
@case
def ability_lists_from_dbm():
    w = World()
    c = Client(w, "Bob", guild_rank=0, class_file="MAGE")
    c.load_addon()
    w.tick(2)
    council = c.eval_py("return ns.Data.BossAbilities['BlackTemple:Council']")
    casts = {x["id"]: x for x in (council["c"].values() if isinstance(council["c"], dict) else council["c"])}
    assert casts[41455].get("int") is True and casts[41455].get("cd") == 14, casts
    assert casts[41472].get("int") is True and 41471 in casts and not casts[41471].get("int"), casts
    auras = list(council["a"].values()) if isinstance(council["a"], dict) else council["a"]
    assert 41450 in auras and 41451 in auras, auras
    maulgar = c.eval_py("return ns.Data.BossAbilities['GruulsLair:Maulgar']")
    ints = [x["id"] for x in (maulgar["c"].values() if isinstance(maulgar["c"], dict) else maulgar["c"]) if x.get("int")]
    assert sorted(ints) == [33144, 33152], ints
    assert c.eval("local n = 0; for _ in pairs(ns.Data.BossAbilities) do n = n + 1 end; return n") >= 45
    w.assert_no_errors()


@case
def only_the_chosen_abilities_count_and_dbm_gives_the_rhythm():
    w, c, occ, sid, npcs = raid()
    for n in ("Rog", "Sham", "Tom", "Bob"):
        see(w, c[n], "Malande", npcs=npcs)
    engage(w, c)
    mal, rog = npcs["Malande"], c["Rog"]
    # Empowered Smite isn't one of the table's abilities: nobody is told to kick it
    cleu(w, "SPELL_CAST_START", mal, None, 41471, "Empowered Smite")
    assert lines(rog).get("flash") is None and rot_state(rog).get("nextIn") is None
    # Circle of Healing is: Rog's kick; after one cast DBM's cooldown (14 s) already says when the next one comes
    cleu(w, "SPELL_CAST_START", mal, None, 41455, "Circle of Healing")
    assert lines(rog)["flash"] == "KICK NOW: Circle of Healing"
    cleu(w, "SPELL_CAST_SUCCESS", rog, mal, 1769, "Kick")
    w.tick(1.0, step=0.1)
    n = rot_state(rog)["nextIn"]
    assert n is not None and 12 <= n <= 13.2, n
    # Divine Wrath is one too
    cleu(w, "SPELL_CAST_START", mal, None, 41472, "Divine Wrath")
    assert lines(c["Sham"])["flash"] == "KICK NOW: Divine Wrath"
    w.assert_no_errors()


@case
def immunities_skip_the_interrupts_that_cant_land():
    w, c, occ, sid, npcs = raid()
    for n in ("Rog", "Sham", "Tom", "Bob"):
        see(w, c[n], "Malande", npcs=npcs)
    engage(w, c)
    mal, rog, sham = npcs["Malande"], c["Rog"], c["Sham"]
    assert pick(rog) == (K("Rog"), "main")
    # Blessing of Protection: Kick can't land -> the shaman takes it, the rogue's panel says why
    cleu(w, "SPELL_AURA_APPLIED", mal, mal, 41450, "Blessing of Protection", "BUFF")
    assert pick(rog) == (K("Sham"), "main"), pick(rog)
    assert rot_item(rog)["status"] == "immune to yours", rot_item(rog)
    cleu(w, "SPELL_CAST_START", mal, None, 41455, "Circle of Healing")
    assert lines(sham)["flash"] == "KICK NOW: Circle of Healing" and lines(rog).get("flash") is None
    cleu(w, "SPELL_CAST_SUCCESS", sham, mal, 10414, "Earth Shock")
    # ... and Tom (the backup, a warrior: Pummel is physical too) isn't called either while it lasts
    assert pick(rog)[0] != K("Tom")
    cleu(w, "SPELL_AURA_REMOVED", mal, mal, 41450, "Blessing of Protection", "BUFF")
    assert pick(rog)[0] == K("Rog")
    # Blessing of Spell Warding: the other way round (Earth Shock can't land, Kick can)
    w.tick(10, step=0.5)
    cleu(w, "SPELL_AURA_APPLIED", mal, mal, 41451, "Blessing of Spell Warding", "BUFF")
    s = rot_state(rog)
    assert s["pick"] in (K("Rog"), K("Tom")) and s["pick"] != K("Sham"), s
    w.assert_no_errors()


@case
def conditional_rows():
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    # Sham's row only when Malande has Blessing of Protection; Tom's (the backup) only when she's below 30%
    set_rows(bob, sid, {2: "a:41450", 3: "hp:30"})
    w.tick(2)
    bob.eval("ns.StrategyBoard:Close()")
    for n in ("Rog", "Sham", "Tom", "Bob"):
        see(w, c[n], "Malande", npcs=npcs)
    engage(w, c)
    mal, rog, sham, tom = npcs["Malande"], c["Rog"], c["Sham"], c["Tom"]
    assert pick(rog) == (K("Rog"), "main")
    assert rot_item(sham)["status"] == "only when BoP", rot_item(sham)
    # Rog kicks; with Sham's row asleep, nobody else is on the rotation -> Rog is next again (late if not ready)
    cleu(w, "SPELL_CAST_START", mal, None, 41455, "Circle of Healing")
    cleu(w, "SPELL_CAST_SUCCESS", rog, mal, 1769, "Kick")
    assert pick(rog)[0] == K("Rog")
    # Blessing of Protection: Sham's row wakes up and takes the turn
    cleu(w, "SPELL_AURA_APPLIED", mal, mal, 41450, "Blessing of Protection", "BUFF")
    assert pick(sham) == (K("Sham"), "cond"), pick(sham)
    assert rot_item(sham)["status"] == "BoP: your turn", rot_item(sham)
    assert rot_item(bob, overview=True)["status"] == "Sham's turn (BoP)", rot_item(bob, overview=True)
    cleu(w, "SPELL_AURA_REMOVED", mal, mal, 41450, "Blessing of Protection", "BUFF")
    # below 30%: Tom's row wakes up (the health of what the clients can see, read twice a second)
    w.set_npc_hp(mal, 25)
    w.tick(0.6, step=0.1)
    assert pick(tom) == (K("Tom"), "cond"), pick(tom)
    assert rot_item(tom)["status"] == "< 30%: your turn", rot_item(tom)
    w.assert_no_errors()


@case
def editor_menus():
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    B = "_G.CDLootStrategyBoard.blocks"
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi'); %s:CellMenu(UIParent, k, 1, 3)" % B)
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Circle of Healing (interrupt)  ~14 s" in texts and "Empowered Smite" in texts, texts
    assert "Blessing of Protection" in texts and "Below health..." in texts, texts
    # untick Divine Wrath, tick Empowered Smite; only when Blessing of Spell Warding
    for label in ("Divine Wrath (interrupt)", "Empowered Smite"):
        bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi'); %s:CellMenu(UIParent, k, 1, 3)" % B)
        bob.eval("""local want = ...
            local function find(d) for _, ch in ipairs(d.children) do
              local t = (ch.text or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''):gsub('|T.-|t', ''):gsub('^%s+', '')
              if t == want then return ch end; local r = find(ch); if r then return r end end end
            local ch = find(__MOCK.last_menu); __MOCK.menu_select(ch.text, ch.parent)""", label)
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi'); %s:CellMenu(UIParent, k, 1, 3)" % B)
    bob.eval("""local function find(d) for _, ch in ipairs(d.children) do
          local t = (ch.text or ''):gsub('|T.-|t', ''):gsub('^%s+', '')
          if t == 'Blessing of Spell Warding' then return ch end; local r = find(ch); if r then return r end end end
        local ch = find(__MOCK.last_menu); __MOCK.menu_select(ch.text, ch.parent)""")
    cell = bob.eval_py("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi').d[1][3]")
    a = sorted(cell["a"].values() if isinstance(cell["a"], dict) else cell["a"])
    assert a == [41455, 41471] and cell["w"] == "a:41451", cell
    # the cell shows it
    txt = strip_codes(bob.eval("for _, b in ipairs(%s.blocks) do for _, cl in ipairs(b.cells) do if cl.targetInfo and "
                               "cl.targetInfo.k.id == 'mi' and cl.targetInfo.row == 1 then return cl.fs:GetText() end end end" % B))
    assert "when BoSW" in txt, txt
    # saved; a cell with a bad condition is dropped
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(2)
    assert bob.eval("return ns.Strategy:FindBlock(ns.Strategy:GetStrategy(...), 'mi').d[1][3].w", sid) == "a:41451"
    assert bob.eval("local s = ns.Util.CopyTable(ns.Strategy:GetStrategy(...)); "
                    "ns.Strategy:FindBlock(s, 'mi').d[1][3].w = 'when bop'; local v = ns.Strategy:Validate(s); "
                    "local k = ns.Strategy:FindBlock(v, 'mi'); return k.d[1] == nil or k.d[1][3] == nil", sid) is True
    w.assert_no_errors()


@case
def curses_by_spell_id():
    """A curse table's rows pick their curse from a list (a spell id): the panel names it, the combat log checks it,
    whichever rank lands; the label is optional."""
    w, c, occ, sid, npcs = raid()
    bob, wal = c["Bob"], c["Wal"]
    B = "_G.CDLootStrategyBoard.blocks"
    assert bob.eval("return ns.Strategy:FindBlock(ns.Strategy:GetStrategy(...), 'cu').d[1][2].a[1]", sid) == 1714
    # the editor: a Curse menu (no Abilities / Only when for a curse table); switch row 1 to Curse of the Elements
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'cu'); %s:CellMenu(UIParent, k, 1, 2)" % B)
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Curse: Curse of Tongues" in texts and "Curse of the Elements" in texts and "Curse of Doom" in texts, texts
    assert not any(t.startswith("Abilities") or t.startswith("Only when") for t in texts), texts
    bob.eval("""local function find(d) for _, ch in ipairs(d.children) do
          local t = (ch.text or ''):gsub('|T.-|t', ''):gsub('^%s+', '')
          if t == 'Curse of the Elements' then return ch end; local r = find(ch); if r then return r end end end
        local ch = find(__MOCK.last_menu); __MOCK.menu_select(ch.text, ch.parent)""")
    txt = strip_codes(bob.eval("for _, b in ipairs(%s.blocks) do for _, cl in ipairs(b.cells) do if cl.targetInfo and "
                               "cl.targetInfo.k.id == 'cu' and cl.targetInfo.row == 1 then return cl.fs:GetText() end end end" % B))
    assert txt.strip() == "Curse of the Elements", txt
    bob.eval("ns.StrategyBoard:Save(); ns.StrategyBoard:Close()")
    w.tick(10)
    for n in ("Wal", "Bob"):
        see(w, c[n], "Malande", npcs=npcs)
    engage(w, c)
    mine = [x for x in lines(wal)["lines"] if x.startswith("Curse of the Elements on Lady Malande:")]
    assert mine, lines(wal)
    # a higher rank's id lands (27228): matched by the picked curse's name
    cleu(w, "SPELL_AURA_APPLIED", wal, npcs["Malande"], 27228, "Curse of the Elements", "DEBUFF")
    assert wal.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'curse' "
                    "then return t.rows[1].up == true and t.rows[1].curseId == 1490 end end") is True
    # the old one on the same row doesn't count any more
    cleu(w, "SPELL_AURA_REMOVED", wal, npcs["Malande"], 27228, "Curse of the Elements", "DEBUFF")
    cleu(w, "SPELL_AURA_APPLIED", wal, npcs["Malande"], 11719, "Curse of Tongues", "DEBUFF")
    assert lines(wal)["flash"] == "Your Curse of the Elements fell off", lines(wal)
    w.assert_no_errors()


@case
def tables_made_before_tracking():
    """A copy made before "Track in fight" existed: its interrupt table has boss abilities picked but no tracking, its
    curse table curses picked. Practice (and the live helpers) follow them anyway; with nothing to follow, practice
    says how to set it up."""
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="ROGUE")
    bob.load_addon()
    w.tick(3)
    open_full_starter(bob, BOSS)
    bob.eval("local s = ns.StrategyBoard:GetState().strat; "
             "for _, p in ipairs(s.p) do for _, k in ipairs(p.k) do k.tr = nil; k.bk = nil end end; "
             "ns.StrategyBoard:Save(); ns.StrategyBoard:Close()", BOSS)
    w.tick(1)
    assert bob.eval("local s = ns.Strategy:GetStrategies(...)[1]; return ns.Strategy.TrackKind(ns.Strategy:FindBlock(s, 'mi')) "
                    ".. ',' .. ns.Strategy.TrackKind(ns.Strategy:FindBlock(s, 'cu')) .. ',' .. "
                    "tostring(ns.Strategy.TrackKind(ns.Strategy:FindBlock(s, 'md')))", BOSS) == "rot,curse,nil"
    bob.slash("/cdl strat practice council")
    w.tick(4 + 1, step=0.25)
    L = bob.eval_py("return ns.StrategyReminder:Lines()")["lines"]
    assert any(x.startswith("Malande interrupts: [YOU]") for x in L), L
    bob.slash("/cdl strat stop")
    # nothing tracked or picked at all: practice explains
    bob.eval("local s = ns.Util.CopyTable(ns.Strategy:GetStrategies(...)[1]); "
             "for _, p in ipairs(s.p) do for _, k in ipairs(p.k) do for _, cells in pairs(k.d or {}) do "
             "for _, v in pairs(cells) do if type(v) == 'table' then v.a = nil end end end end end; "
             "ns.StrategyPractice:Start(s)", BOSS)
    assert any("no tables the encounter helpers follow" in m for m in bob.chat_frame[-4:]), bob.chat_frame[-4:]
    bob.slash("/cdl strat stop")
    # the editor: picking abilities in an untracked table tracks it as an interrupt rotation
    bob.eval("ns.StrategyBoard:OpenStrategy(ns.Strategy:GetStrategies(...)[1].id, 'edit'); "
             "local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi'); k.tr = nil; "
             "for _, cells in pairs(k.d) do for _, v in pairs(cells) do if type(v) == 'table' then v.a = nil end end end", BOSS)
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi'); "
             "_G.CDLootStrategyBoard.blocks:CellMenu(UIParent, k, 1, 3)")
    bob.eval("""local function find(d) for _, ch in ipairs(d.children) do
          local t = (ch.text or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''):gsub('|T.-|t', ''):gsub('^%s+', '')
          if t == 'Divine Wrath (interrupt)' then return ch end; local r = find(ch); if r then return r end end end
        local ch = find(__MOCK.last_menu); __MOCK.menu_select(ch.text, ch.parent)""")
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'mi').tr") == "rot"
    w.assert_no_errors()


@case
def slot_menu_by_table_and_long_rows_wrap():
    """"Show a slot's player" lists one submenu per table (the flat list ran off the screen); a reminder row too long for
    one line ("Misdirect Shade of Akama onto Dalia...") wraps to a second line instead of being cut off."""
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    bob.eval("local k = ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'md'); "
             "_G.CDLootStrategyBoard.blocks:CellMenu(UIParent, k, 1, 3)")
    tops = bob.eval_py("""local out = {}
        for _, ch in ipairs(__MOCK.last_menu.children) do
          if (ch.text or ''):find("Show a slot's player", 1, true) then
            for _, t in ipairs(ch.children) do
              local subs = {}
              for _, x in ipairs(t.children or {}) do subs[#subs + 1] = x.text end
              out[#out + 1] = { t = t.text, subs = subs }
            end
          end
        end
        return out""")
    names = [strip_codes(t["t"]) for t in tops]
    assert names[0] == "None" and "Tanks" in names and "Malande interrupts" in names and len(names) < 16, names
    tanks = [t for t in tops if strip_codes(t["t"]) == "Tanks"][0]
    subs = list(tanks["subs"].values()) if isinstance(tanks["subs"], dict) else tanks["subs"]
    assert "Gathios (MT) · Tank" in subs, subs
    # the Gathios misdirect shows this slot: the top row of the submenu is highlighted
    assert any(strip_codes(t["t"]) == "Tanks" and t["t"] != "Tanks" for t in tops), tops
    bob.eval("ns.StrategyBoard:Close()")
    # a long row wraps
    hun = c["Hana"]
    see(w, hun, "Gathios", npcs=npcs)
    hun.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'md' then "
             "for _, r in ipairs(t.rows) do r.label = 'Illidari Nightlord'; r.onto = 'Bartholomew-Thunderstrike' end end end; "
             "ns.StrategyReminder:Refresh()")
    got = hun.eval_py("""local f = _G.CDLootStrategyReminder; local out = {}
        for _, r in ipairs(f.rows or {}) do
          if r:IsShown() and (r.text:GetText() or ''):find('Misdirect', 1, true) then
            out[#out + 1] = { text = r.text:GetText(), h = r:GetHeight(), wrap = r.text:CanWordWrap() }
          end
        end
        return out""")
    got = list(got.values()) if isinstance(got, dict) else got
    assert got and strip_codes(got[0]["text"]) == "Misdirect Illidari Nightlord onto Bartholomew", got
    assert got[0]["wrap"] is True and got[0]["h"] > 20, got
    w.assert_no_errors()


@case
def practice_shows_an_immunity():
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="ROGUE")
    bob.load_addon()
    w.tick(3)
    open_full_starter(bob, BOSS)
    bob.eval("ns.StrategyBoard:Save(); ns.StrategyBoard:Close()")
    w.tick(1)
    bob.slash("/cdl strat practice council")
    w.tick(4 + 23, step=0.25)           # the pull, then the target gains Blessing of Protection 22 s in
    it = rot_item(bob)
    assert it["status"] == "immune to yours", it     # I'm the rogue: my Kick can't land
    w.tick(12, step=0.25)
    assert rot_item(bob)["status"] != "immune to yours"
    bob.slash("/cdl strat stop")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
