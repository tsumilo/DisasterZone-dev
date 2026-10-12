"""ADDENDUM K: dispel tables (block.tr = "dsp"), on the real addon.

A table of the people who remove an effect: a curse / magic / poison / disease on our raid, or a magic buff / an enrage
on the enemy. Nobody takes turns: everyone in the table is told at once while the effect is up, and the alert ends for
all of them when it is gone.

Covers: the removable effects generated per boss (wowhead's dispel types), the block's fields validated and the
classes that can remove each type, an effect landing on raid members (everyone in the table alerted, nobody else, the
leader's overview, removal / the carrier's death ending it, a dead dispeller left alone), a table left empty (everyone
whose class can remove it), an enemy's buff (only on creatures), the editor (the template, picking the effect sets the
type and who fits, Type / Where, the line under the title) and the practice run.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_dispel.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import open_full_starter  # noqa: E402
from test_strategy_live import (raid, see, engage, end_encounter, cleu, lines, items, ASSIGN, BOSS, K)  # noqa: E402
from _common import World, Client, case, run_all, strip_codes, menu_texts  # noqa: E402
import _common  # noqa: E402

del _common._CASES[:]       # the live suite's cases were registered by the import: run only this file's

DIVINE_WRATH = 41472        # Lady Malande's, here as a Magic debuff on the raid
SPELL_WARDING = 41451       # Blessing of Spell Warding on a council member: Magic, on the enemy
B = "_G.DisasterZoneStrategyBoard.blocks"

# on our raid: Pri and Gina (a paladin) dispel; on the enemy: Sham purges; a decurse table nobody is put in
BLOCKS = """
return {
  { id = 'dp', n = 'Dispels', r = 2, tr = 'dsp', dy = 'm', ds = { 41472 }, c = { { t = 'p', n = 'Player', f = 'PRIEST,PALADIN,WARLOCK' } } },
  { id = 'pu', n = 'Purges', r = 1, tr = 'dsp', dy = 'm', en = true, ds = { 41451 }, c = { { t = 'p', n = 'Player', f = 'PRIEST,SHAMAN,MAGE,WARLOCK' } } },
  { id = 'dc', n = 'Decurse', r = 2, tr = 'dsp', dy = 'c', ds = { 31972 }, c = { { t = 'p', n = 'Player', f = 'MAGE,DRUID' } } },
}
"""
FILL = {"dp.1.1": "Pri", "dp.2.1": "Gina", "pu.1.1": "Sham"}


def dispel_raid():
    """The live suite's Council raid with three dispel tables added to the plan and filled."""
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    # (the notes block makes room: a page holds 12 blocks)
    bob.eval("local ks = (loadstring(...))(); local p = ns.StrategyBoard:GetState().strat.p[1]; table.remove(p.k); "
             "for _, k in ipairs(ks) do p.k[#p.k + 1] = k end; ns.StrategyBoard:Save(); ns.StrategyBoard:Close()", BLOCKS)
    w.tick(3)
    assert bob.eval("return ns.Strategy:FindBlock(ns.Strategy:GetStrategy(...), 'dc') ~= nil", sid)
    a = {ref: K(n) for ref, n in ASSIGN.items()}
    a.update({ref: K(n) for ref, n in FILL.items()})
    res = bob.eval_py("local o, b, s, a = ...; local ok, e = ns.Strategy:SaveFill(o, b, s, a); return { ok = ok, e = e }",
                      occ, BOSS, sid, a)
    assert res["ok"], res
    w.tick(10)
    for x in c.values():
        x.eval("ns.StrategyLive:Reset()")
    for n in ("Pri", "Gina", "Sham", "Rog", "Dru", "Wal", "Bob", "Lee"):
        see(w, c[n], "Malande", npcs=npcs)
    return w, c, occ, sid, npcs


def row(cl, table, overview=False):
    """The reminder item of a dispel table (by the table's id), text and status without colours."""
    if not cl.eval("return ns.StrategyReminder:Items() ~= nil"):
        return None
    for it in items(cl):
        tr = it.get("tr")
        if tr and tr.get("id") == table and bool(it.get("overview")) == overview:
            return {"text": strip_codes(it["text"]), "status": strip_codes(it.get("status") or ""),
                    "alert": bool(it.get("alert")), "detail": strip_codes(it.get("detail") or "").strip()}
    return None


def pick_in_menu(cl, label):
    """Clicks the entry of the open menu whose text (colours, icons and leading spaces aside) is `label`."""
    cl.eval("""local want = ...
        local function find(d) for _, ch in ipairs(d.children) do
          local t = (ch.text or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''):gsub('|T.-|t', ''):gsub('^%s+', '')
          if t == want then return ch end; local r = find(ch); if r then return r end end end
        local ch = assert(find(__MOCK.last_menu), want); __MOCK.menu_select(ch.text, ch.parent)""", label)


def dispels_of(cl, ref):
    d = cl.eval_py("return ns.Strategy:GetBossDispels(...)", ref)
    d = list(d.values()) if isinstance(d, dict) else d
    return {x["id"]: x for x in d}


# ------------------------------------------------------------------------------------------------------------------
@case
def removable_effects_per_boss():
    w = World()
    c = Client(w, "Bob", guild_rank=0, class_file="MAGE")
    c.load_addon()
    w.tick(2)
    zj = dispels_of(c, "ZulAman:Zuljin")
    assert zj[43095]["t"] == "m" and not zj[43095].get("en"), zj          # Creeping Paralysis: Magic, on the raid
    hz = dispels_of(c, "ZulAman:Halazzi")
    assert hz[43139]["t"] == "e" and hz[43139].get("en") is True, hz      # Frenzy: an enrage sits on the enemy
    tw = dispels_of(c, "SunwellPlateau:EredarTwins")
    assert tw[45230]["t"] == "m" and tw[45230].get("en") is True, tw      # Pyrogenics: DBM tells the purgers
    assert dispels_of(c, "HyjalSummit:Archimonde")[31972]["t"] == "c"     # Grip of the Legion: a curse
    assert 38235 not in dispels_of(c, "SerpentshrineCavern:Hydross")      # Water Tomb can't be removed
    # an effect typed in by id is recognised when any boss' list knows it
    assert c.eval_py("return { ns.Strategy:DispelTypeOf(43139) }") in (["e", True], {1: "e", 2: True})
    assert c.eval("return ns.Strategy:DispelTypeOf(12345)") is None
    w.assert_no_errors()


@case
def fields_and_who_can_remove():
    w = World()
    c = Client(w, "Bob", guild_rank=0, class_file="MAGE")
    c.load_addon()
    w.tick(2)
    F = "return ns.Strategy.DispelFilter(...)"
    assert c.eval(F, "c", False) == "MAGE,DRUID"
    assert c.eval(F, "p", False) == "DRUID,PALADIN,SHAMAN"
    assert c.eval(F, "d", False) == "PRIEST,PALADIN,SHAMAN"
    assert c.eval(F, "m", False) == "PRIEST,PALADIN,WARLOCK"
    assert c.eval(F, "m", True) == "PRIEST,SHAMAN,MAGE,WARLOCK"
    assert c.eval(F, "e", True) == "HUNTER"
    # Enrage is only ever on the enemy, a curse only on ours
    assert c.eval("return ns.Strategy.DispelSide('e', false)") is True
    assert c.eval("return ns.Strategy.DispelSide('c', true)") is False
    V = ("local d = ns.Strategy:NewDraft('BlackTemple:Council', 'x', 0); local k = (loadstring('return ' .. ...))(); "
         "d.p[1].k[1] = k; local v = ns.Strategy:Validate(d); return v and v.p[1].k[1] or false")
    k = c.eval_py(V, "{ id = 'k1', n = 'D', r = 1, tr = 'dsp', dy = 'c', en = true, ds = { 31972, 31972, 5 }, c = { { t = 'p' } } }")
    ds = list(k["ds"].values()) if isinstance(k["ds"], dict) else k["ds"]
    assert k["tr"] == "dsp" and k["dy"] == "c" and k["en"] is True and ds == [31972, 5], k
    for bad in ("dy = 'x'", "en = 1", "ds = { 'a' }", "ds = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }"):
        assert c.eval(V, "{ id = 'k1', n = 'D', r = 1, tr = 'dsp', %s, c = { { t = 'p' } } }" % bad) is False, bad
    w.assert_no_errors()


@case
def everyone_in_the_table_is_told_at_once():
    w, c, occ, sid, npcs = dispel_raid()
    pri, gina, rog, bob, lee = c["Pri"], c["Gina"], c["Rog"], c["Bob"], c["Lee"]
    # near the boss: the two dispellers have the job, a rogue hasn't
    assert row(pri, "dp") == {"text": "Dispel Divine Wrath", "status": "watch for it", "alert": False, "detail": ""}, row(pri, "dp")
    assert row(gina, "dp") and row(rog, "dp") is None
    engage(w, c)
    assert row(pri, "dp")["status"] == "clear"
    # it lands on Lee: both are told now, nobody else
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], lee, DIVINE_WRATH, "Divine Wrath", "DEBUFF")
    for x in (pri, gina):
        r = row(x, "dp")
        assert r["status"] == "NOW: Lee" and r["alert"], r
        assert lines(x)["flash"] == "Dispel Divine Wrath from Lee", lines(x)
    assert row(rog, "dp") is None and not (lines(rog) or {}).get("flash")
    # the raid leader (not in the table) sees who is on it and that it is up
    o = row(bob, "dp", overview=True)
    assert o["detail"] == "Pri, Gina" and o["status"] == "on Lee" and not o["alert"], o
    # a second carrier; the longest first
    w.tick(1)
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], rog, DIVINE_WRATH, "Divine Wrath", "DEBUFF")
    assert row(pri, "dp")["status"] == "NOW: Lee, Rog", row(pri, "dp")
    # someone removes Lee's (the combat log shows the aura gone, whoever did it): the alert goes on for Rog's
    cleu(w, "SPELL_AURA_REMOVED", npcs["Malande"], lee, DIVINE_WRATH, "Divine Wrath", "DEBUFF")
    assert row(gina, "dp")["status"] == "NOW: Rog", row(gina, "dp")
    # Rog dies with it: nothing left to remove, for everyone at once
    cleu(w, "UNIT_DIED", None, rog)
    for x in (pri, gina):
        assert row(x, "dp") == {"text": "Dispel Divine Wrath", "status": "clear", "alert": False, "detail": ""}, row(x, "dp")
    # the same effect on an enemy is none of this table's business, another spell neither
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], npcs["Gathios"], DIVINE_WRATH, "Divine Wrath", "BUFF")
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], lee, 41476, "Spell 41476", "DEBUFF")
    assert row(pri, "dp")["status"] == "clear"
    w.assert_no_errors()


@case
def a_dead_dispeller_is_left_alone():
    w, c, occ, sid, npcs = dispel_raid()
    pri, gina, lee = c["Pri"], c["Gina"], c["Lee"]
    engage(w, c)
    w.set_dead(pri)
    w.tick(0.3)
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], lee, DIVINE_WRATH, "Divine Wrath", "DEBUFF")
    r = row(pri, "dp")
    assert r["status"] == "you're dead" and not r["alert"], r
    assert row(gina, "dp")["alert"]
    w.assert_no_errors()


@case
def an_empty_table_means_everyone_who_can():
    w, c, occ, sid, npcs = dispel_raid()
    bob, dru, rog, wal, pri = c["Bob"], c["Dru"], c["Rog"], c["Wal"], c["Pri"]
    engage(w, c)
    # nobody was put in the decurse table: the mage and the druid have it, nobody else
    assert row(bob, "dc")["text"] == "Decurse Spell 31972" and row(dru, "dc"), (row(bob, "dc"), row(dru, "dc"))
    assert row(rog, "dc") is None and row(pri, "dc") is None and row(wal, "dc") is None
    cleu(w, "SPELL_AURA_APPLIED", npcs["Gathios"], rog, 31972, "Spell 31972", "DEBUFF")
    for x in (bob, dru):
        assert row(x, "dc")["status"] == "NOW: Rog" and row(x, "dc")["alert"], row(x, "dc")
    cleu(w, "SPELL_AURA_REMOVED", npcs["Gathios"], rog, 31972, "Spell 31972", "DEBUFF")
    assert row(bob, "dc")["status"] == "clear"
    # a table with names is theirs alone: the warlock (Magic, with a Felhunter) isn't told about "dp"
    assert row(wal, "dp") is None
    w.assert_no_errors()


@case
def a_buff_on_the_enemy():
    w, c, occ, sid, npcs = dispel_raid()
    sham, bob, lee = c["Sham"], c["Bob"], c["Lee"]
    engage(w, c)
    assert row(sham, "pu")["text"] == "Purge Blessing of Spell Warding", row(sham, "pu")
    # on a player it isn't this table's (someone spellstole it)
    cleu(w, "SPELL_AURA_APPLIED", bob, bob, SPELL_WARDING, "Blessing of Spell Warding", "BUFF")
    assert row(sham, "pu")["status"] == "clear"
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], npcs["Zerevor"], SPELL_WARDING, "Blessing of Spell Warding", "BUFF")
    r = row(sham, "pu")
    assert r["status"] == "NOW: High Nethermancer Zerevor" and r["alert"], r
    assert lines(sham)["flash"] == "Purge Blessing of Spell Warding on High Nethermancer Zerevor", lines(sham)
    assert row(bob, "pu", overview=True)["detail"] == "Sham"
    cleu(w, "SPELL_AURA_REMOVED", npcs["Malande"], npcs["Zerevor"], SPELL_WARDING, "Blessing of Spell Warding", "BUFF")
    assert row(sham, "pu")["status"] == "clear"
    # a new pull starts clean
    cleu(w, "SPELL_AURA_APPLIED", npcs["Malande"], npcs["Zerevor"], SPELL_WARDING, "Blessing of Spell Warding", "BUFF")
    assert row(sham, "pu")["alert"]
    end_encounter(w, c, False)
    engage(w, c)
    assert row(sham, "pu")["status"] == "clear"
    w.assert_no_errors()


@case
def the_editor():
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="MAGE")
    bob.load_addon()
    w.tick(3)
    bob.eval("ns.StrategyBoard:NewStrategy('ZulAman:Halazzi', 'dispels')")
    # the template (Add a block's Dispels card): a Magic table for our raid, priests / paladins / warlocks fit
    bob.eval("for _, c in ipairs(%s.cards) do if c:IsShown() and c.title:GetText() == 'Dispels' then c:Click() end end" % B)
    K1 = "local p = ns.StrategyBoard:GetState().strat.p[1]; local k = p.k[#p.k]; "
    k = bob.eval_py(K1 + "return { tr = k.tr, dy = k.dy, en = k.en, f = k.c[1].f, ds = k.ds }")
    assert k == {"tr": "dsp", "dy": "m", "f": "PRIEST,PALADIN,WARLOCK"}, k

    def strip():
        return strip_codes(bob.eval("local id = ...; for _, b in ipairs(%s.blocks) do if b:IsShown() and b.blockId == id then "
                                    "for _, cl in ipairs(b.cells) do if cl.blockId == id then return cl.fs:GetText() end end end end"
                                    % B, bob.eval(K1 + "return k.id"))).strip()
    assert strip() == "click to pick the effect to remove", strip()
    # the gear menu offers the boss' removable effects with their type; Frenzy is an enrage on the enemy
    bob.eval(K1 + "%s:BlockMenu(UIParent, p, k, #p.k)" % B)
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Effects to remove" in texts and "Type  Magic" in texts and "Where  on our raid" in texts, texts
    assert "Spell 43139  Enrage (on the enemy)" in texts, texts
    pick_in_menu(bob, "Spell 43139  Enrage (on the enemy)")
    k = bob.eval_py(K1 + "return { dy = k.dy, en = k.en, f = k.c[1].f, ds = k.ds }")
    ds = list(k["ds"].values()) if isinstance(k["ds"], dict) else k["ds"]
    assert k["dy"] == "e" and k["en"] is True and k["f"] == "HUNTER" and ds == [43139], k
    assert strip() == "Spell 43139  Enrage, on the enemy", strip()
    # an effect by id that no list knows keeps the table's type; a known one of another type starts the table over
    bob.eval(K1 + "%s:BlockMenu(UIParent, p, k, #p.k)" % B)
    pick_in_menu(bob, "By spell ID")
    bob.type_text(bob.eval("return ns.StrategyBoard:GetPrompt().editBox"), "99999", enter=True)
    w.tick(0.3)
    k = bob.eval_py(K1 + "return { dy = k.dy, en = k.en, ds = k.ds }")
    ds = list(k["ds"].values()) if isinstance(k["ds"], dict) else k["ds"]
    assert k["dy"] == "e" and ds == [43139, 99999], k
    assert strip() == "Spell 43139 +1  Enrage, on the enemy", strip()
    bob.eval(K1 + "%s:BlockMenu(UIParent, p, k, #p.k)" % B)
    pick_in_menu(bob, "By spell ID")
    bob.type_text(bob.eval("return ns.StrategyBoard:GetPrompt().editBox"), "31972", enter=True)     # Grip of the Legion
    w.tick(0.3)
    k = bob.eval_py(K1 + "return { dy = k.dy, en = k.en, f = k.c[1].f, ds = k.ds }")
    ds = list(k["ds"].values()) if isinstance(k["ds"], dict) else k["ds"]
    assert k == {"dy": "c", "f": "MAGE,DRUID", "ds": k["ds"]} and ds == [31972], k
    # view mode: the line stays, without the hint
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(2)
    bob.eval("ns.StrategyBoard:OpenStrategy(ns.Strategy:GetStrategies('ZulAman:Halazzi')[1].id)")
    assert strip() == "Spell 31972  Curse, on our raid", strip()
    w.assert_no_errors()


@case
def type_and_where():
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="MAGE")
    bob.load_addon()
    w.tick(3)
    bob.eval("ns.StrategyBoard:NewStrategy('SunwellPlateau:EredarTwins', 'dispels')")
    bob.eval("local p = ns.StrategyBoard:GetState().strat.p[1]; local k = ns.StrategyBlocksUI.TEMPLATES[6].make(); "
             "k.id = 'k1'; p.k[1] = k; %s:Render()" % B)
    K1 = "local p = ns.StrategyBoard:GetState().strat.p[1]; local k = p.k[1]; "

    def menu(label):
        bob.eval(K1 + "%s:BlockMenu(UIParent, p, k, 1)" % B)
        pick_in_menu(bob, label)
        return bob.eval_py(K1 + "return { dy = k.dy, en = k.en, f = k.c[1].f, ds = k.ds }")
    # Where: the enemy -> the purgers fit; back to our raid
    assert menu("On the enemy (purge / spellsteal)") == {"dy": "m", "en": True, "f": "PRIEST,SHAMAN,MAGE,WARLOCK"}
    assert menu("On our raid (dispel it off a player)") == {"dy": "m", "f": "PRIEST,PALADIN,WARLOCK"}
    # Type: Curse -> mages and druids, and no Where (a curse is only ever on ours)
    assert menu("Curse") == {"dy": "c", "f": "MAGE,DRUID"}
    bob.eval(K1 + "%s:BlockMenu(UIParent, p, k, 1)" % B)
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Type  Curse" in texts and not any(t.startswith("Where") for t in texts), texts
    # Pyrogenics (DBM: for the purgers) makes it a Magic table on the enemy in one click
    k = menu("Spell 45230  Magic (on the enemy)")
    ds = list(k["ds"].values()) if isinstance(k["ds"], dict) else k["ds"]
    assert k["dy"] == "m" and k["en"] is True and k["f"] == "PRIEST,SHAMAN,MAGE,WARLOCK" and ds == [45230], k
    # it saves and comes back whole
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(2)
    k = bob.eval_py("local k = ns.Strategy:GetStrategies('SunwellPlateau:EredarTwins')[1].p[1].k[1]; "
                    "return { tr = k.tr, dy = k.dy, en = k.en, n = #k.ds }")
    assert k == {"tr": "dsp", "dy": "m", "en": True, "n": 1}, k
    # "Track in fight" lists it, and the title row says so (a green tag after the title)
    title = strip_codes(bob.eval("return %s.blocks[1].title.fs:GetText()" % B))
    tag = bob.eval("local t = %s.blocks[1].tag; return t:IsShown() and t.fs:GetText()" % B)
    assert title == "Dispels" and tag == "Dispels", (title, tag)
    w.assert_no_errors()


@case
def practice_shows_the_effect():
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="PRIEST")
    bob.load_addon()
    w.tick(3)
    open_full_starter(bob, BOSS)
    bob.eval("local ks = (loadstring(...))(); local p = ns.StrategyBoard:GetState().strat.p[1]; "
             "p.k[#p.k + 1] = ks[1]; ns.StrategyBoard:Save(); ns.StrategyBoard:Close()", BLOCKS)
    w.tick(1)
    bob.slash("/dz strat practice council")
    w.tick(4 + 2, step=0.25)
    assert row(bob, "dp")["status"] == "clear", row(bob, "dp")
    # the effect lands on a demo player some seconds into the fight, and goes again
    seen = False
    for _ in range(80):
        w.tick(0.25, step=0.25)
        r = row(bob, "dp")
        if r["alert"]:
            seen = True
            assert r["status"].startswith("NOW: "), r
            break
    assert seen
    w.tick(8, step=0.25)
    assert row(bob, "dp")["status"] == "clear", row(bob, "dp")
    bob.slash("/dz strat stop")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
