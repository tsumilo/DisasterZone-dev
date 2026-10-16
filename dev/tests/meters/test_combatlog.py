"""The shared combat-log reader and death-recap recorder (Core/CombatLog.lua), refactor 1.4 phase 4.

Covers: COMBAT_LOG_EVENT_UNFILTERED read once per event for Meters, My Log and the swing timer together (each
subscribes only while it needs the log: Meters while on, My Log during a pull, the swing timer while it runs and twist
practice does not); one hit counted by all three (damage with its overkill in Meters and My Log alike, decision D5;
the swing timer's clock); a failing subscriber not stopping the others; one death recorded by the one recorder in
both saved orders (Meters: source at 5, health at 6; My Log: health at 5, source at 6, as 1.3.5 saved it); the ring
turning over and the recap window.

Run: luaenv\\Scripts\\python.exe tests\\meters\\test_combatlog.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

ME_FLAGS = 0x511
BOSS_FLAGS = 0xA48

COUNT_READS = """
    if not __realCLEU then
        __realCLEU = CombatLogGetCurrentEventInfo
        CombatLogGetCurrentEventInfo = function(...) __reads = (__reads or 0) + 1; return __realCLEU(...) end
    end
    __reads = 0
"""


class Pull:
    """Gina, a Retribution Paladin (so the swing timer runs), in Serpentshrine Cavern with Meters and My Log on."""

    def __init__(self, meters=True, mylog=True):
        w = World()
        w.auto_session = False
        cl = Client(w, "Gina", class_file="PALADIN", guild_rank=3, talents=(5, 11, 45))
        cl.load_addon()
        cl.eval("ns.ClassKit:SetOn('swing', true)")       # (class tools start off: the Ret timer switched on)
        w.tick(3)
        if meters:
            cl.eval("ns.DB:SetSetting('meters.dmg', true)")
        if mylog:
            cl.eval("ns.DB:SetSetting('mylog.enabled', true)")
        w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
        w.tick(1)
        self.w, self.cl = w, cl
        self.me = cl.eval("return UnitGUID('player')")
        self.boss = w.spawn_npc(21216, "Hydross the Unstable")

    def ev(self, sub, src, src_name, src_flags, dst, dst_name, dst_flags, *rest):
        self.cl.combat_log(self.cl.eval("return GetTime()"), sub, False, src or "", src_name or "", src_flags, 0,
                           dst or "", dst_name or "", dst_flags, 0, *rest)

    def swing(self, amount, overkill=-1):
        self.ev("SWING_DAMAGE", self.me, "Gina", ME_FLAGS, self.boss, "Hydross the Unstable", BOSS_FLAGS,
                amount, overkill, 1, None, None, None, False, False, False, False)

    def start(self):
        self.cl.fire("ENCOUNTER_START", 623, "Hydross the Unstable", 4, 25)

    def end(self, kill=True):
        self.cl.fire("ENCOUNTER_END", 623, "Hydross the Unstable", 4, 25, 1 if kill else 0)

    def subscribed(self):
        return self.cl.eval_py("local CL = ns.CombatLog; return { meter = CL:IsSubscribed('meter'), "
                               "mylog = CL:IsSubscribed('mylog'), swing = CL:IsSubscribed('swing'), "
                               "on = CL:IsListening() }")


@case
def one_read_per_event_for_all_three():
    p = Pull()
    cl = p.cl
    assert cl.eval("return ns.SwingTimer.active") is True
    assert p.subscribed() == {"meter": True, "mylog": False, "swing": True, "on": True}     # My Log: only in a pull
    p.start()
    assert p.subscribed() == {"meter": True, "mylog": True, "swing": True, "on": True}
    cl.eval(COUNT_READS)
    p.swing(2500, overkill=600)                     # the killing blow on whatever it was: overkill counts (D5)
    with_all = cl.eval("return __reads")
    now = cl.eval("return GetTime()")
    # Meters, My Log and the swing timer each saw the hit
    assert cl.eval("return ns.Meter:GetLive().actors[...].d", p.me) == 2500
    assert cl.eval("return ns.MyLog:GetCurrent().dmg['0'].a") == 2500
    assert abs(cl.eval("return ns.SwingTimer.state.last") - now) < 0.001
    p.w.tick(4)
    p.end(kill=True)
    pull = cl.eval_py("local ps = ns.MyLog:GetPulls(); return ps[#ps].s")
    assert pull["d"] == 2500, pull                  # the same number Meters show
    # everyone off: no subscriber left, the event goes unregistered (other modules may still read the log)
    cl.eval("ns.DB:SetSetting('meters.dmg', false); ns.DB:SetSetting('swing.enabled', false)")
    assert p.subscribed() == {"meter": False, "mylog": False, "swing": False, "on": False}
    cl.eval("__reads = 0")
    p.swing(1000)
    without = cl.eval("return __reads")
    assert with_all - without == 1, (with_all, without)
    assert p.cl.errors == []


@case
def practice_owns_the_swing_state():
    p = Pull(meters=False, mylog=False)
    cl = p.cl
    assert p.subscribed()["swing"] is True
    cl.eval("ns.SwingTimer.practice = {}; ns.SwingTimer:Refresh()")
    assert p.subscribed() == {"meter": False, "mylog": False, "swing": False, "on": False}
    cl.eval("ns.SwingTimer.state.last = nil")
    p.swing(1000)
    assert cl.eval("return ns.SwingTimer.state.last") is None
    cl.eval("ns.SwingTimer.practice = nil; ns.SwingTimer:Refresh()")
    assert p.subscribed()["swing"] is True
    p.swing(1000)
    assert cl.eval("return ns.SwingTimer.state.last") is not None


@case
def a_failing_subscriber_does_not_stop_the_others():
    p = Pull(mylog=False)
    cl = p.cl
    # a subscriber that errors, reading before Meters (Meters off and on again: it subscribes after it)
    cl.eval("ns.DB:SetSetting('meters.dmg', false); "
            "ns.CombatLog:Subscribe('boom', function() error('boom') end); ns.DB:SetSetting('meters.dmg', true)")
    assert cl.eval("return ns.CombatLog:IsSubscribed('boom') and ns.CombatLog:IsSubscribed('meter')") is True
    cl.clear_errors()
    p.swing(1800)
    assert cl.eval("return ns.Meter:GetLive().actors[...].d", p.me) == 1800
    errs = cl.errors
    assert len(errs) == 1 and "boom" in errs[0], errs
    cl.clear_errors()
    cl.eval("ns.CombatLog:Unsubscribe('boom')")
    assert cl.eval("return ns.CombatLog:IsSubscribed('boom')") is False


@case
def one_death_recorded_in_both_saved_orders():
    p = Pull()
    cl = p.cl
    p.start()
    cl.eval("__MOCK.player_hp = 6400")
    p.ev("SPELL_DAMAGE", p.boss, "Hydross the Unstable", BOSS_FLAGS, p.me, "Gina", ME_FLAGS,
         38235, "Water Tomb", 16, 2600, -1, 16, None, None, None, False, False, False, False)
    p.w.tick(1)
    cl.eval("__MOCK.player_hp = 0")
    p.ev("SPELL_DAMAGE", p.boss, "Hydross the Unstable", BOSS_FLAGS, p.me, "Gina", ME_FLAGS,
         38235, "Water Tomb", 16, 7000, 600, 16, None, None, 300, False, False, False, False)
    p.ev("UNIT_DIED", "", "", 0, p.me, "Gina", ME_FLAGS)
    p.w.tick(1)
    p.end(kill=False)
    m = cl.eval_py("return ns.Meter:GetSegment('cur').deaths[1]")
    assert m["by"] == 38235 and m["src"] == "Hydross the Unstable", m
    # Meters: { dt, kind, key, amount, source, health, overkill }
    assert [e[1] for e in m["ev"]] == ["d", "d"], m["ev"]
    assert m["ev"][0][4] == "Hydross the Unstable" and m["ev"][0][5] == 6400, m["ev"]
    assert m["ev"][1][4] == "Hydross the Unstable" and m["ev"][1][5] == 0 and m["ev"][1][6] == 600, m["ev"]
    assert m["ev"][0][0] == -1.0 and m["ev"][1][0] == 0, m["ev"]
    # My Log (its 1.3.5 order): { dt, kind, key, amount, health, source, absorbed }
    d = cl.eval_py("local ps = ns.MyLog:GetPulls(); return ps[#ps].deaths[1]")
    assert d["by"] == "38235", d
    ring = d["ring"]
    assert [e[1] for e in ring] == ["d", "d"], ring
    assert ring[0][4] == 6400 and ring[0][5] == "Hydross the Unstable", ring
    assert ring[1][4] == 0 and ring[1][5] == "Hydross the Unstable" and ring[1][6] == 300, ring
    assert ring[0][0] == -1.0 and ring[1][0] == 0, ring
    assert p.cl.errors == []


@case
def the_ring_turns_over_and_the_recap_keeps_its_window():
    p = Pull(meters=False, mylog=False)
    out = p.cl.eval_py("""
        local CL = ns.CombatLog
        local r = CL.NewRing(4)
        for i = 1, 6 do CL.Push(r, i, i % 2 == 0 and 'd' or 'h', 'k' .. i, i * 10, 'src' .. i, 100 - i, nil) end
        local third = r[3]
        CL.Push(r, 7, 'd', 'k7', 70, 'src7', 93, 5)
        local list, by, bySrc = CL.Recap(r, 7, 2.5, 10)
        local reused = r[3] == third and third[3] == 'k7'
        CL.ClearRing(r)
        local empty = CL.Recap(r, 7, 10, 10)
        return { n = #list, t1 = list[1][1], key1 = list[1][3], by = by, bySrc = bySrc, last = list[#list],
                 reused = reused, empty = #empty, pos = r.pos }
    """)
    # pushes 1..7 into 4 slots: 4..7 kept; a 2.5 s window before t = 7 keeps 5, 6, 7 (oldest first)
    assert out["n"] == 3 and out["t1"] == -2 and out["key1"] == "k5", out
    assert out["by"] == "k7" and out["bySrc"] == "src7", out
    assert out["last"] == [0, "d", "k7", 70, "src7", 93, 5], out["last"]
    assert out["reused"] is True and out["empty"] == 0 and out["pos"] == 0, out


if __name__ == "__main__":
    run_all()
