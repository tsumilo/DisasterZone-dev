"""ADDENDUM K: encounter helpers (Core/StrategyLive.lua, UI/StrategyReminder.lua), on the real addon.

A simulated Illidari Council raid: the Council starter strategy saved by the raid leader, a planned raid with sign-ups
and names, a raid session linked to it, the four council members as enemy NPCs (nameplates, target), the encounter
events and the combat log as the Anniversary client sends them.

Covers: auto-marking from the portraits' raid marks on the raid leader's client only (nameplates, the plan wins over
another addon per mob, the strategy / Settings switches, mobs outside the plan untouched), the reminder near the boss
(my jobs only, the leader's overview, nothing for players without jobs, the setting), the interrupt rotation (turns,
hits and misses counted once, the target's cast flashing the current player, a missed turn moving on, a kick on
another mob ignored, a kick out of turn, a dead player skipped), once-per-pull / cooldown / keep-up tables
(Misdirection, Bloodlust countdown, Power Infusion and Innervate cooldowns, a curse falling off), the end of the
encounter fading the panel, the plan without a linked raid, the authoring switches and /cdl strat.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_live.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import K, DAY, now, create, signup, strategies  # noqa: E402
from rp_common import set_raid_leaders  # noqa: E402
from _common import World, Client, gm_pick, case, run_all, strip_codes, printed_since  # noqa: E402

BOSS = "BlackTemple:Council"
ENC = 608
NPC = {"Gathios": 22949, "Zerevor": 22950, "Malande": 22951, "Veras": 22952}
FULL = {"Gathios": "Gathios the Shatterer", "Zerevor": "High Nethermancer Zerevor", "Malande": "Lady Malande",
        "Veras": "Veras Darkshadow"}
MARK = {"Gathios": 8, "Veras": 7, "Malande": 1, "Zerevor": 6}

# name, class, guild rank, spec index
ROSTER = (("Gina", "PALADIN", 0, 2), ("Bob", "MAGE", 1, 1), ("Lee", "WARRIOR", 3, 3), ("Tom", "WARRIOR", 3, 3),
          ("Rog", "ROGUE", 3, 1), ("Sham", "SHAMAN", 3, 2), ("Hana", "HUNTER", 3, 1), ("Hugo", "HUNTER", 3, 1),
          ("Wal", "WARLOCK", 3, 1), ("Wes", "WARLOCK", 3, 1), ("Pri", "PRIEST", 3, 1), ("Dru", "DRUID", 3, 3),
          ("Zed", "ROGUE", 3, 1))

ASSIGN = {
    "tk.1.1": "Lee", "tk.2.1": "Gina", "tk.3.1": "Tom", "tk.4.1": "Bob",
    "mi.1.2": "Rog", "mi.2.2": "Sham", "mi.3.2": "Tom",
    "md.1.2": "Hana", "md.2.2": "Hugo",
    "cu.1.1": "Wal", "cu.2.1": "Wes",
    "bl.1.1": "Sham",
    "pi.1.1": "Pri", "pi.1.2": "Bob",
    "iv.1.1": "Dru", "iv.1.2": "Pri",
    "hl.1.1": "Pri",
}


def raid(link=True, start_session=True):
    w = World()
    c = {}
    for n, cls, rank, _ in ROSTER:
        c[n] = Client(w, n, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    bob = c["Bob"]
    # the Council starter, saved
    bob.eval("ns.StrategyBoard:NewFromStarter(...)", BOSS)
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(2)
    sid = strategies(bob, BOSS)[0]["id"]
    occ = None
    if link:
        occ = create(bob, i="bt", t=now(bob) + 1800)
        w.tick(2)
        for n, _, _, sp in ROSTER:
            assert signup(c[n], occ, "A", sp)["ok"], n
        w.tick(2)
        res = bob.eval_py("local o, b, s, a = ...; local ok, e = ns.Strategy:SaveFill(o, b, s, a); return { ok = ok, e = e }",
                          occ, BOSS, sid, {ref: K(n) for ref, n in ASSIGN.items()})
        assert res["ok"], res
        w.tick(2)
    w.make_raid([bob] + [c[n] for n, _, _, _ in ROSTER if n != "Bob"], leader=bob, assistants=[c["Gina"]])
    w.tick(4)
    if start_session:
        bob.slash("/cdl raid start")
        w.tick(6)
        s = bob.eval_py("return ns.GroupRules:GetSession()")
        if link:
            assert s and s["rp"] == occ, s
    npcs = {k: w.spawn_npc(NPC[k], FULL[k]) for k in NPC}
    for x in c.values():
        x.eval("ns.StrategyLive:Reset()")
    return w, c, occ, sid, npcs


def cleu(w, sub, src, dst, spell_id=0, spell_name=None, *extra):
    """One combat log event to the whole raid. src / dst: a Client (player) or an NPC guid, or None."""
    def unit(x):
        if x is None:
            return "", None, 0
        if isinstance(x, str):
            return x, w.npcs[x]["name"], 0xa48
        return x.guid, x.name, 0x514
    sg, sn, sf = unit(src)
    dg, dn, df = unit(dst)
    args = [w.now, sub, False, sg, sn, sf, 0, dg, dn, df, 0]
    if sub != "UNIT_DIED":
        args += [spell_id, spell_name, 1]
    args += list(extra)
    w.cleu_group(*args)
    w.tick(0.1)


def engage(w, c):
    for x in c.values():
        x._fire("ENCOUNTER_START", ENC, "Illidari Council", 4, 25)
    w.tick(0.2)


def end_encounter(w, c, success):
    for x in c.values():
        x._fire("ENCOUNTER_END", ENC, "Illidari Council", 4, 25, 1 if success else 0)
    w.tick(0.2)


def see(w, cl, *names, npcs):
    for n in names:
        cl.show_nameplate(npcs[n])
    w.tick(0.2)


def lines(cl):
    d = cl.eval_py("return ns.StrategyReminder:Lines()")
    if not d:
        return None
    d["lines"] = [strip_codes(x) for x in (d["lines"].values() if isinstance(d["lines"], dict) else d["lines"])]
    d["title"] = strip_codes(d["title"])
    return d


def mark_of(w, guid):
    return w.marks.get(guid)


# ------------------------------------------------------------------------------------------------------------------
@case
def marks_from_the_plan_on_the_leaders_client_only():
    w, c, occ, sid, npcs = raid()
    # a raider (not the leader) sees them: nothing is marked
    see(w, c["Lee"], "Gathios", "Veras", "Malande", "Zerevor", npcs=npcs)
    assert w.marks == {} and not [m for m in w.mark_log if m["by"] == K("Lee")], w.mark_log
    # the assistant doesn't mark either (only the raid leader's client does)
    see(w, c["Gina"], "Gathios", npcs=npcs)
    assert w.marks == {}
    # the raid leader's nameplates: every council member gets the mark of its portrait
    see(w, c["Bob"], "Gathios", "Veras", "Malande", "Zerevor", npcs=npcs)
    assert {k: mark_of(w, g) for k, g in npcs.items()} == MARK, w.marks
    # everyone in the raid sees them
    assert c["Rog"].eval("return __MOCK.marks[...]", npcs["Malande"]) == 1
    # another addon moves Gathios' skull: the plan puts it back (after the anti-fight gap)
    w.set_mark_by_other(npcs["Gathios"], 3)
    w.tick(2)
    assert mark_of(w, npcs["Gathios"]) == 8, w.marks
    # a mob the plan doesn't mark is left alone
    other = w.spawn_npc(23330, "Illidari Elite")
    see(w, c["Bob"], npcs=npcs)
    c["Bob"].show_nameplate(other)
    w.tick(0.3)
    assert mark_of(w, other) is None
    w.assert_no_errors()


@case
def marking_switches():
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    # Settings: off
    bob.eval("ns.DB:SetSetting('strategy.autoMark', false)")
    see(w, bob, "Gathios", npcs=npcs)
    assert w.marks == {}
    bob.eval("ns.DB:SetSetting('strategy.autoMark', true)")
    # the strategy's own switch (the board's Auto-mark checkbox while editing)
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    bob.click(bob.eval("return _G.CDLootStrategyBoard.autoMark"))
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(2)
    assert strategies(bob, BOSS)[0].get("am") is False
    bob.eval("ns.StrategyLive:Reset()")
    bob.hide_nameplate(npcs["Gathios"])
    see(w, bob, "Gathios", "Veras", npcs=npcs)
    assert w.marks == {}, w.marks
    w.assert_no_errors()


@case
def reminder_near_the_boss_shows_my_jobs():
    w, c, occ, sid, npcs = raid()
    # nothing before a planned mob is seen
    assert lines(c["Rog"]) is None
    see(w, c["Rog"], "Malande", npcs=npcs)
    d = lines(c["Rog"])
    assert d["title"].startswith("The Illidari Council") and "next" in d["title"], d
    assert "Malande interrupts: [YOU] > Sham > Tom" in d["lines"], d["lines"]
    assert "  Your kick is next" in d["lines"], d["lines"]
    assert c["Rog"].eval("local f = ns.StrategyReminder:GetFrame(); return f ~= nil and f:IsShown()") is True
    # a tank sees their tank job (a plain table)
    see(w, c["Lee"], "Gathios", npcs=npcs)
    assert "- Tanks: Gathios (MT)" in lines(c["Lee"])["lines"], lines(c["Lee"])
    # the warlock: their curse row
    see(w, c["Wal"], "Veras", npcs=npcs)
    assert any(x.startswith("Curse of Tongues:") for x in lines(c["Wal"])["lines"]), lines(c["Wal"])
    # somebody without a job on this boss sees nothing
    see(w, c["Zed"], "Malande", npcs=npcs)
    assert lines(c["Zed"]) is None
    # the raid leader: own jobs + the overview of every tracked table
    see(w, c["Bob"], "Zerevor", npcs=npcs)
    L = lines(c["Bob"])["lines"]
    assert "- Tanks: Zerevor (mage, Dampen Magic)" in L, L
    assert "Raid" in L and any(x.strip().startswith("Misdirects:") for x in L) and any(x.strip().startswith("Curses:") for x in L), L
    # the setting turns it off
    c["Rog"].eval("ns.DB:SetSetting('strategy.reminder', false)")
    assert lines(c["Rog"]) is None
    w.assert_no_errors()


@case
def interrupt_rotation_follows_the_combat_log():
    w, c, occ, sid, npcs = raid()
    for n in ("Rog", "Sham", "Tom", "Bob"):
        see(w, c[n], "Malande", npcs=npcs)
    engage(w, c)
    mal = npcs["Malande"]
    rog, sham, tom = c["Rog"], c["Sham"], c["Tom"]

    def turn(cl):
        return cl.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'rot' then "
                       "local r = t.order[t.cur]; return r and r.player end end")
    assert turn(rog) == K("Rog")
    # Malande starts Circle of Healing: Rog's panel flashes, Sham's doesn't
    cleu(w, "SPELL_CAST_START", mal, None, 25807, "Circle of Healing")
    assert lines(rog)["flash"] == "KICK NOW: Circle of Healing", lines(rog)
    assert lines(sham).get("flash") is None
    # Rog kicks it: Sham's turn, the flash goes
    cleu(w, "SPELL_CAST_SUCCESS", rog, mal, 1769, "Kick")
    cleu(w, "SPELL_INTERRUPT", rog, mal, 1769, "Kick", 25807, "Circle of Healing", 2)
    assert turn(rog) == turn(sham) == turn(c["Bob"]) == K("Sham")
    assert lines(rog).get("flash") is None
    assert "Malande interrupts: Rog > [YOU] > Tom" in lines(sham)["lines"]
    # Sham's Earth Shock misses: the cast and the miss count once -> Tom
    cleu(w, "SPELL_CAST_SUCCESS", sham, mal, 10414, "Earth Shock")
    cleu(w, "SPELL_MISSED", sham, mal, 10414, "Earth Shock", "RESIST")
    assert turn(sham) == K("Tom")
    # a kick on another mob doesn't count
    cleu(w, "SPELL_CAST_SUCCESS", tom, npcs["Gathios"], 6554, "Pummel")
    assert turn(tom) == K("Tom")
    # Malande casts and Tom doesn't kick in time: the turn moves on to Rog
    cleu(w, "SPELL_CAST_START", mal, None, 41472, "Divine Wrath")
    assert lines(tom)["flash"] == "KICK NOW: Divine Wrath"
    w.tick(3.5)
    assert turn(tom) == turn(rog) == K("Rog")
    # a kick out of turn (Sham while it's Rog's): the rotation continues after Sham -> Tom
    cleu(w, "SPELL_CAST_SUCCESS", sham, mal, 10414, "Earth Shock")
    assert turn(rog) == K("Tom")
    # Tom dies: his turn is skipped -> Rog
    cleu(w, "UNIT_DIED", None, tom)
    assert turn(rog) == K("Rog")
    assert any("Tom (dead)" in x for x in lines(rog)["lines"]), lines(rog)
    w.assert_no_errors()


@case
def once_cooldown_and_keep_up_tables():
    w, c, occ, sid, npcs = raid()
    for n in ("Hana", "Hugo", "Sham", "Pri", "Dru", "Wal", "Bob"):
        see(w, c[n], "Gathios", npcs=npcs)
    engage(w, c)
    hana, sham, pri, dru, wal = c["Hana"], c["Sham"], c["Pri"], c["Dru"], c["Wal"]

    def my(cl, prefix):
        return [x for x in lines(cl)["lines"] if x.startswith(prefix)]
    # Misdirection: pending until cast
    assert my(hana, "Misdirect Gathios >") and "Lee" in my(hana, "Misdirect Gathios >")[0], lines(hana)
    cleu(w, "SPELL_CAST_SUCCESS", hana, npcs["Gathios"], 34477, "Misdirection")
    assert c["Hana"].eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'md' "
                          "then return t.rows[1].done end end") is True
    # Bloodlust: the "When" countdown, then done
    assert "in 15 s" in my(sham, "Bloodlust")[0] or "in 1" in my(sham, "Bloodlust")[0], my(sham, "Bloodlust")
    w.tick(16, step=0.5)
    assert "NOW" in my(sham, "Bloodlust")[0]
    cleu(w, "SPELL_CAST_SUCCESS", sham, sham, 2825, "Bloodlust")
    assert "NOW" not in my(sham, "Bloodlust")[0]
    # Power Infusion -> Bob, Innervate -> Pri: ready, then on cooldown, ready again
    assert my(pri, "Power Infusion > ")[0].endswith("ready"), lines(pri)
    cleu(w, "SPELL_CAST_SUCCESS", pri, c["Bob"], 10060, "Power Infusion")
    assert my(pri, "Power Infusion > ")[0].endswith("3:00") or my(pri, "Power Infusion > ")[0].endswith("2:59")
    cleu(w, "SPELL_CAST_SUCCESS", dru, pri, 29166, "Innervate")
    assert "Innervate > " in my(dru, "Innervate")[0] and my(dru, "Innervate")[0].endswith(("6:00", "5:59"))
    w.tick(181, step=1)
    assert my(pri, "Power Infusion > ")[0].endswith("ready")
    # Curse of Tongues on Malande: up, then it falls off -> the warlock's panel flashes
    cleu(w, "SPELL_AURA_APPLIED", wal, npcs["Malande"], 11719, "Curse of Tongues", "DEBUFF")
    assert my(wal, "Curse of Tongues")[0].rstrip().endswith(":"), my(wal, "Curse of Tongues")    # the ready icon
    assert wal.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'curse' "
                    "then return t.rows[1].up end end") is True
    assert "OK" not in lines(wal)["lines"][0]
    cleu(w, "SPELL_AURA_REMOVED", wal, npcs["Malande"], 11719, "Curse of Tongues", "DEBUFF")
    d = lines(wal)
    assert "fell off" in my(wal, "Curse of Tongues")[0] and d["flash"] == "Your Curse of Tongues fell off", d
    # the raid leader's overview has every table
    L = lines(c["Bob"])["lines"]
    assert any(x.strip().startswith("Power Infusion:") for x in L) and any(x.strip().startswith("Innervates:") for x in L), L
    w.assert_no_errors()


@case
def the_end_of_the_encounter_fades_the_panel():
    w, c, occ, sid, npcs = raid()
    rog = c["Rog"]
    see(w, rog, "Malande", npcs=npcs)
    engage(w, c)
    assert "engaged" in lines(rog)["title"]
    end_encounter(w, c, True)
    assert "killed" in lines(rog)["title"]
    w.tick(11)
    assert lines(rog) is None
    w.tick(2)
    assert rog.eval("local f = ns.StrategyReminder:GetFrame(); return f:IsShown()") is False
    # a wipe keeps the plan for the next pull; the next pull starts the trackers over
    see(w, rog, "Malande", npcs=npcs)
    engage(w, c)
    cleu(w, "SPELL_CAST_SUCCESS", rog, npcs["Malande"], 1769, "Kick")
    end_encounter(w, c, False)
    assert "wipe" in lines(rog)["title"]
    engage(w, c)
    assert "Malande interrupts: [YOU] > Sham > Tom" in lines(rog)["lines"]
    w.assert_no_errors()


@case
def without_a_linked_raid():
    w, c, occ, sid, npcs = raid(link=False, start_session=False)
    bob = c["Bob"]
    see(w, bob, "Gathios", "Malande", npcs=npcs)
    # the guild's strategy still marks (no names needed for that)
    assert mark_of(w, npcs["Gathios"]) == 8 and mark_of(w, npcs["Malande"]) == 1
    d = lines(bob)
    assert "(no raid linked)" in strip_codes(bob.eval("return ns.StrategyReminder:Lines().sub")), d
    assert lines(c["Rog"]) is None          # no names, no jobs
    w.assert_no_errors()


@case
def authoring_and_slash():
    w, c, occ, sid, npcs = raid()
    bob = c["Bob"]
    # the Track in fight menu of a table
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    bob.eval("local B = _G.CDLootStrategyBoard.blocks; for _, b in ipairs(B.blocks) do if b.blockId == 'hl' then "
             "b.gear:Click() end end")
    bob.eval("""
        local function find(d, t) for _, ch in ipairs(d.children) do if ch.text == t then return ch end
          local r = find(ch, t); if r then return r end end end
        __MOCK.menu_select('Power Infusion', find(__MOCK.last_menu, 'Track in fight'))""")
    assert bob.eval("return ns.Strategy:FindBlock(ns.StrategyBoard:GetState().strat, 'hl').tr") == "pi"
    assert bob.eval("return (ns.Strategy:Validate(ns.StrategyBoard:GetState().strat)) ~= nil") is True
    bob.eval("ns.StrategyBoard:CancelChanges()")
    # /cdl strat
    n0 = len(bob.chat_frame)
    bob.slash("/cdl strat")
    assert any("No boss nearby" in strip_codes(x) for x in printed_since(bob, n0))
    see(w, bob, "Veras", npcs=npcs)
    bob.slash("/cdl strat debug")
    n0 = len(bob.chat_frame)
    cleu(w, "SPELL_CAST_SUCCESS", c["Hugo"], npcs["Zerevor"], 34477, "Misdirection")
    assert any("[strat]" in strip_codes(x) and "Misdirection" in strip_codes(x) for x in printed_since(bob, n0))
    n0 = len(bob.chat_frame)
    bob.slash("/cdl strat")
    assert any("Near The Illidari Council" in strip_codes(x) for x in printed_since(bob, n0))
    # the setup check (works solo): settings, leader, nameplates, spells, the linked raid's bosses
    n0 = len(bob.chat_frame)
    bob.slash("/cdl strat check")
    out = [strip_codes(x) for x in printed_since(bob, n0)]
    assert any("You lead the group" in x and x.endswith("yes") for x in out), out
    assert any("Enemy nameplates on" in x and x.endswith("yes") for x in out), out
    assert any("Tracked spells known to this client: all" in x for x in out), out
    assert any("Raid session linked to a planned raid: Black Temple" in x for x in out), out
    council = [x for x in out if "The Illidari Council:" in x]
    assert council and "marks 4 creature(s)" in council[0] and "6 tracked table(s)" in council[0], out
    assert "your jobs: 1" in council[0] or "your jobs: 2" in council[0], council
    w.assert_no_errors()


@case
def practice_solo_at_a_target_dummy():
    # Bob alone (no group, no raid), the Council starter open on the board
    w = World()
    bob = Client(w, "Bob", guild_rank=0, class_file="ROGUE")
    bob.load_addon()
    w.tick(3)
    bob.eval("ns.StrategyBoard:NewFromStarter(...)", BOSS)
    bob.eval("ns.StrategyBoard:Save()")
    w.tick(1)
    bob.click(bob.eval("return _G.CDLootStrategyBoard.practiceBtn"))
    w.tick(0.3)
    d = lines(bob)
    assert "PRACTICE" in strip_codes(bob.eval("return ns.StrategyReminder:Lines().sub")), d
    L = d["lines"]
    # me: the first row of every tracked table and one plain job; demo players everywhere else
    assert "- Tanks: Gathios (MT)" in L, L
    assert any(x.startswith("Malande interrupts: [YOU] > ") for x in L), L
    assert any(x.startswith("Misdirect Gathios >") for x in L) and any(x.startswith("Curse of Tongues:") for x in L), L
    assert "Raid" not in L                               # I'm in every tracked table: no overview repeating them
    assert "next" in d["title"]
    w.tick(4.5, step=0.25)
    assert "engaged" in lines(bob)["title"]
    # the first cast: my turn -> KICK NOW; my real Kick on a training dummy counts
    w.tick(2, step=0.25)
    assert lines(bob)["flash"].startswith("KICK NOW"), lines(bob)
    dummy = w.spawn_npc(31146, "Raider's Training Dummy")
    bob.combat_log(w.now, "SPELL_CAST_SUCCESS", False, bob.guid, "Bob", 0x511, 0, dummy, "Raider's Training Dummy",
                   0xa48, 0, 1766, "Kick", 1)
    w.tick(0.2)
    L = lines(bob)["lines"]
    assert lines(bob).get("flash") is None and any(x.startswith("Malande interrupts: YOU > [") for x in L), L

    def turn():
        return bob.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'rot' "
                        "then return t.cur end end")
    # the next cast is a demo player's turn, and they kick it themselves: the turn moves on
    assert turn() == 2
    w.tick(7.5, step=0.25)
    assert turn() == 3, turn()
    # marking what I target: the plan's marks in board order (Skull, Cross, ...)
    bob.target_npc(dummy)
    w.tick(0.2)
    assert bob.eval("return GetRaidTargetIndex('target')") == 8
    other = w.spawn_npc(31144, "Training Dummy")
    bob.target_npc(other)
    w.tick(0.2)
    assert bob.eval("return GetRaidTargetIndex('target')") == 7
    # a demo warlock's curse falls off: the overview shows it
    w.tick(12, step=0.5)
    assert bob.eval("local c = ns.StrategyLive:GetCurrent(); for _, t in ipairs(c.trackers) do if t.kind == 'curse' "
                    "then return t.rows[2].fellAt ~= nil and not t.rows[2].up end end") is True
    # the kill at the end, then the panel goes
    w.tick(45, step=0.5)
    assert "killed" in lines(bob)["title"], lines(bob)
    w.tick(12, step=0.5)
    assert lines(bob) is None
    # /cdl strat practice <boss> and stop
    bob.eval("ns.StrategyBoard:Close()")
    bob.slash("/cdl strat practice council")
    w.tick(0.3)
    assert lines(bob) is not None
    bob.slash("/cdl strat stop")
    w.tick(0.3)
    assert lines(bob) is None
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
