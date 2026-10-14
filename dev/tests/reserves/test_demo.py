"""The loot reserves demo (1.4.3, Core/ReserveDemo.lua + UI/Reserves.lua's panel): a made-up pug night, step by step,
on one character outside any group. Every step in every view must run clean, show what it says and send nothing."""
from rv_common import *  # noqa: F403
from harness import World, Client  # noqa: E402

R = Runner("reserves / the demo")


def solo():
    w = World()
    c = Client(w, "Tsumil", class_file="PALADIN", guild_rank=0)
    c.load_addon()
    w.tick(3)
    return w, c


def state(c):
    return c.eval_py(r"""
        local d = ns.ReserveDemo:GetState()
        local L = ns.Reserves:Get()
        local n = 0
        for _, set in pairs(L and L.r or {}) do for _ in pairs(set) do n = n + 1 end end
        local f = DisasterZoneReserveDemo
        return { step = d.step, view = d.view, running = ns.ReserveDemo:IsRunning(), list = L ~= nil,
                 open = L and L.o or false, reserves = n, lines = #ns.ReserveDemo:Lines(),
                 panel = f and f:IsShown() or false, title = f and f.title:GetText() or "",
                 win = DisasterZoneReserves and DisasterZoneReserves:IsShown() or false,
                 view_pick = ns.ReservesUI:GetState().view }""")


def step_to(w, c, n, wait=4):
    c.eval("ns.ReserveDemo:Go(...)", n)
    w.tick(wait)
    return state(c)


@R.case
def the_whole_night_as_the_raid_leader():
    w, c = solo()
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    c.slash("/dz reserves demo")
    w.tick(2)
    s = state(c)
    assert s["running"] and s["step"] == 1 and s["panel"] and s["title"] == "Set up", s
    assert c.eval("return ns.Util.DemoOn()")
    assert c.eval("local p = ns.SessionBar:GetPick(); return p and p.reserve") is True
    s = step_to(w, c, 2)
    assert s["list"] and s["open"] and s["win"] and s["lines"] >= 3, s
    s = step_to(w, c, 3, wait=6)
    assert s["reserves"] >= 8, s
    lines = c.eval_py("local out = {}; for i, l in ipairs(ns.ReserveDemo:Lines()) do out[i] = l.text end; return out")
    assert any(l.startswith("[DZ] Reserved") for l in lines), lines
    assert any("held for the guild" in l for l in lines), lines
    s = step_to(w, c, 4)
    assert c.eval_py("return ns.Reserves:SourceOf(ns.Util.PlayerKey(), 30108)") == "d"
    s = step_to(w, c, 5)
    assert not s["open"], s
    s = step_to(w, c, 6)
    assert c.eval("return ns.DropPanel.frame and ns.DropPanel.frame:IsShown()"), "drop panel"
    blocks = c.eval_py(r"""local out = {}
        for _, b in ipairs(ns.DropPanel.blocks) do if b:IsShown() then out[#out + 1] = { i = b.itemID, k = b.rvKind,
          sub = b.sub:GetText() or "" } end end; return out""")
    kinds = {b["i"]: b["k"] for b in blocks}
    assert kinds == {30108: "s", 30105: "s", 30103: "g", 30109: "o"}, blocks
    # Roll all plays the four
    c.eval("ns.DropPanel:RollAll()")
    w.tick(60)
    s = step_to(w, c, 7)
    rows = c.eval_py("local out = {}; for i, r in ipairs(ns.ReserveIO:WrapUp()) do out[i] = { i = r.itemID, "
                     "how = r.how, w = r.winner } end; return out")
    assert len(rows) >= 3 and all(r.get("w") for r in rows), rows
    assert s["win"] and s["view_pick"] == "wrap", s
    # nothing left the client
    # nothing went to a raid, a whisper or LootReserve (the guild's own background sync goes on as always)
    sent = [e for e in w.addon_log[log0:] if e["sender"].startswith("Tsumil")
            and (e["chat_type"] in ("RAID", "PARTY", "WHISPER") or e["prefix"].startswith("LootReserve"))]
    assert not sent, sent
    assert not [e for e in w.chat_log[chat0:] if e["sender"].startswith("Tsumil")], w.chat_log[chat0:]
    c.eval("ns.ReserveDemo:Stop()")
    w.tick(1)
    assert not state(c)["panel"]
    w.assert_no_errors()


@R.case
def every_step_in_every_view_runs_clean():
    w, c = solo()
    c.slash("/dz reserves demo")
    w.tick(2)
    for view in ("lead", "raider", "pug"):
        c.eval("ns.ReserveDemo:SetView(...)", view)
        for n in range(1, 8):
            s = step_to(w, c, n, wait=5 if n != 6 else 40)
            assert s["running"] and s["view"] == view and s["step"] == n, (view, n, s)
            if view == "pug":
                assert not s["win"], (view, n, s)
    # the raider sees the roll pop-up for their own reserve and only a line for the longbow
    c.eval("ns.ReserveDemo:SetView('raider')")
    step_to(w, c, 5)
    step_to(w, c, 6, wait=3)
    w.assert_no_errors()


@R.case
def back_and_forth_keeps_one_night():
    w, c = solo()
    c.slash("/dz reserves demo")
    for n in (3, 2, 3, 5, 4, 6, 1, 7):
        step_to(w, c, n, wait=3)
    assert c.eval("return ns.ReserveDemo:IsRunning()")
    c.eval("ns.Demo:SetEnabled(false)")
    w.tick(1)
    assert not c.eval("return ns.ReserveDemo:IsRunning()")
    assert c.eval_py("return ns.Reserves:Get()") is None
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)
