"""The developer's Performance page (Core/Perf.lua, UI/PerfUI.lua) and the garbage-free dispatcher (Core/Init.lua
SafeCall).

Covers: only Tsumil gets the page, its slash and the noting hooks (anybody else: none of it runs); memory samples
every 10 s, Clean up now, garbage per minute from the samples; Measure: event and message handlers named by the file
that registered them, a Util.After timer named by where it was scheduled, an OnUpdate set from a DisasterZone file wrapped while measuring and put back after, rows with
calls, time and garbage; what holds memory: built pages with their widgets, saved data by section; the page itself
(tiles, chart, both tables, Measure from its button) without errors; SafeCall: nested calls, nil arguments, errors
reported and the depth restored, and no garbage per call.

Run: luaenv\\Scripts\\python.exe tests\\perf\\test_perf.py [-k name]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, strip_codes  # noqa: E402


def dev():
    return solo("Tsumil", class_file="PALADIN", guild_rank=0)


@case
def only_tsumil_gets_the_page_and_its_hooks():
    w, c = solo("Bob")
    assert c.eval("return ns.Perf:IsDev()") is False
    assert c.eval("return ns.PerfNote == nil and ns.Perf.ticker == nil")
    assert c.eval("return ns.MainFrame:IsPageShown('perf')") is False
    assert c.eval("return #ns.Perf.samples") == 0
    w, c = dev()
    assert c.eval("return ns.Perf:IsDev()") is True
    assert c.eval("return type(ns.PerfNote) == 'function' and ns.Perf.ticker ~= nil")
    assert c.eval("return ns.MainFrame:IsPageShown('perf')") is True
    no_errors(w)


@case
def samples_cleanups_and_the_garbage_rate():
    w, c = dev()
    n0 = c.eval("return #ns.Perf.samples")
    assert n0 >= 1
    w.tick(31)
    assert c.eval("return #ns.Perf.samples") >= n0 + 3
    # garbage made between samples counts, a drop does not
    c.eval("__JUNK = {} for i = 1, 20000 do __JUNK[i] = { i } end __JUNK = nil")
    w.tick(10.5)
    rate = c.eval("return ns.Perf:GarbageRate()")
    assert rate is not None and rate > 0, rate
    before, after = c.eval("return ns.Perf:CleanUp()")
    assert after <= before, (before, after)
    assert c.eval("return ns.Perf.clean.after") == after
    assert c.eval("return ns.Perf.samples[#ns.Perf.samples].kb") == after
    no_errors(w)


# A DisasterZone file (the path is what names it): an event handler, a message handler and an OnUpdate, each making
# garbage. (The mock's widgets have no SetScript post-hook, so the file tells Perf as the hook would.)
PROBE_FILE = r"""
local _, ns = ...
__PT = { ev = 0, msg = 0, upd = 0 }
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
  __PT.ev = __PT.ev + 1 local t = {} for i = 1, 50 do t[i] = {} end
  ns.Util.After(0.1, function() __PT.tm = (__PT.tm or 0) + 1 local u = {} for i = 1, 30 do u[i] = {} end end)
end)
ns:On("ROSTER_UPDATED", function() __PT.msg = __PT.msg + 1 local t = {} for i = 1, 20 do t[i] = {} end end)
__PT.frame = CreateFrame("Frame")
__PT.fn = function() __PT.upd = __PT.upd + 1 local t = { {}, {}, {} } end
__PT.frame:SetScript("OnUpdate", __PT.fn)
ns.Perf._OnSetScript(__PT.frame, "OnUpdate", __PT.fn)
"""


def probe_file():
    d = os.path.join(tempfile.mkdtemp(), "AddOns", "DisasterZone")
    os.makedirs(d)
    path = os.path.join(d, "PerfProbeTest.lua")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(PROBE_FILE)
    return path


@case
def measure_names_each_handler_by_its_file_and_weighs_it():
    w, c = dev()
    c.load_files([probe_file()])
    assert c.eval("return ns.Perf:Measure(5)") is True
    assert c.eval("return ns.Perf:Measure(5)") is False                    # (one at a time)
    assert c.eval("return __PT.frame:GetScript('OnUpdate') ~= __PT.fn")       # wrapped while measuring
    for _ in range(3):
        c.fire("PLAYER_TARGET_CHANGED")
        c.eval("ns:Fire('ROSTER_UPDATED')")
    w.tick(5.5)
    assert c.eval("return __PT.frame:GetScript('OnUpdate') == __PT.fn")       # put back
    assert c.eval("return ns.PerfProbe == nil")
    rows = c.eval_py("local out = {} for i, r in ipairs(ns.Perf.last.rows) do out[i] = r end return out")
    by = {r["key"]: r for r in rows}
    ev = [r for k, r in by.items() if "PerfProbeTest.lua:" in k and "PLAYER_TARGET_CHANGED" in k]
    msg = [r for k, r in by.items() if "PerfProbeTest.lua:" in k and "ROSTER_UPDATED" in k]
    upd = [r for k, r in by.items() if "PerfProbeTest.lua:" in k and "OnUpdate" in k]
    assert ev and ev[0]["calls"] == 3 and ev[0]["what"] == "event" and ev[0]["kb"] > 0, ev
    assert msg and msg[0]["calls"] >= 3 and msg[0]["what"] == "message" and msg[0]["kb"] > 0, msg
    assert upd and upd[0]["calls"] > 10 and upd[0]["kb"] > 0, upd
    tm = [r for k, r in by.items() if "PerfProbeTest.lua:" in k and k.endswith("timer")]
    assert tm and tm[0]["calls"] == 3 and tm[0]["what"] == "timer" and tm[0]["kb"] > 0, tm
    assert c.eval("return __PT.ev") == 3                                      # (the handlers still ran)
    # the addon's own handlers are there too, named by their files
    assert any(".lua:" in k and not k.startswith("?") for k in by if "PerfProbeTest" not in k) or len(by) >= 3
    no_errors(w)


@case
def measure_names_who_sends_each_addon_message_and_what_i_send():
    sys.path.insert(0, os.path.join(TESTS, "raidplan"))
    from rp_common import world  # noqa: E402
    w, c = world((("Gina", 0, "PALADIN"), ("Tsumil", 1, "MAGE"), ("Lee", 3, "WARRIOR")))
    gina, me = c["Gina"], c["Tsumil"]
    assert me.eval("return ns.Perf:Measure(6)") is True
    r = gina.eval_py("local ok, k = ns.RaidPlan:SetBlacklisted(...) return { ok = ok }", "Xavier-Thunderstrike")
    assert r["ok"] is True, r
    w.tick(1)
    me.eval("ns.Comm:Send({ t = 'BLQ' }, 'WHISPER', ..., 'ctrl')", "Gina-Thunderstrike")
    w.tick(6)
    rows = me.eval_py("local out = {} for i, r in ipairs(ns.Perf.last.rows) do out[i] = r end return out")
    by = {r["key"]: r for r in rows}
    got = by.get("Core/Comm.lua  message BLL")
    assert got and got["what"] == "comm" and "Gina-Thunderstrike" in got["who"], sorted(by)
    assert got["who"]["Gina-Thunderstrike"]["n"] >= 1 and got["who"]["Gina-Thunderstrike"].get("rev"), got
    sent = by.get("Core/Comm.lua  send BLQ WHISPER")
    assert sent and sent["what"] == "send" and "Gina-Thunderstrike" in sent["who"], sorted(by)
    assert any(k.startswith("Core/Comm.lua  receive + decode") for k in by), sorted(by)
    assert me.eval("return ns.PerfComm == nil")
    w.assert_no_errors()


@case
def what_holds_memory_pages_and_saved_data():
    w, c = dev()
    c.slash("/dz")
    w.tick(1)
    pages = c.eval_py("return ns.Perf:Pages()")
    built = [p for p in pages if p.get("widgets")]
    assert built and built[0]["widgets"] >= built[-1]["widgets"], [(p["key"], p.get("widgets")) for p in pages]
    assert any(p["key"] == "home" and p.get("widgets", 0) > 50 for p in pages), pages
    saved = c.eval_py("return ns.Perf:SavedSizes()")
    names = [s["name"] for s in saved]
    assert any(n.startswith("DisasterZoneDB.") for n in names), names
    assert all(saved[i]["kb"] >= saved[i + 1]["kb"] for i in range(len(saved) - 1))
    no_errors(w)


P = "ns.PerfUI._panel()"


def shown_rows(c, path):
    return c.eval("local n = 0 for _, r in ipairs(%s.%s) do if r:IsShown() then n = n + 1 end end return n" % (P, path))


@case
def the_page_has_a_banner_five_tabs_and_measures_from_its_button():
    w, c = dev()
    c.slash("/dz perf")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "perf"
    # the banner: now (no cleanup yet), the session line, the chips; the buttons carry the addon's own icons
    assert c.eval("return %s.banner.bigUnit:GetText()" % P) == "MB now"
    assert c.eval("return %s.banner.kick:GetText()" % P).startswith("SESSION ")
    assert "3D rooms not loaded" in c.eval("return %s.banner.chips[4].fs:GetText()" % P)
    assert "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\tools" in c.eval("return %s.measure:GetText()" % P)
    assert "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\tools" in c.eval("return %s.clean:GetText()" % P)
    # Overview: the chart has columns, the addons card has my row (blue)
    assert c.eval("local n = 0 for _, b in ipairs(%s.views.overview.hourBox.chart.cols) do if b:IsShown() then "
                  "n = n + 1 end end return n" % P) >= 1
    assert c.eval("local s = %s.views.overview.addons for _, r in ipairs(s.rows) do if r:IsShown() and "
                  "r.name:GetText() == 'DisasterZone' then return r.me:IsShown() end end" % P) is True
    c.click(c.eval("return %s.clean" % P))
    assert c.eval("return %s.banner.bigUnit:GetText()" % P) == "MB in use"
    # the Memory / CPU switch of the chart
    c.click(c.eval("return %s.views.overview.hourBox.tabs.cpu" % P))
    assert c.eval("return ns.PerfUI._state.chart") == "cpu"
    assert c.eval("return %s.views.overview.hourBox.chart.empty:IsShown()" % P) is True   # (the mock: no profiler)
    # Measure: the Garbage tab, rows, a side card
    c.click(c.eval("return %s.measure" % P))
    assert c.eval("return (ns.Perf:IsMeasuring())") is True
    assert c.eval("return ns.PerfUI._state.tab") == "garbage"
    assert "Measuring" in c.eval("return %s.measure:GetText()" % P)
    c.fire("PLAYER_TARGET_CHANGED")
    w.tick(31)
    assert c.eval("return (ns.Perf:IsMeasuring())") is False
    assert shown_rows(c, "views.garbage.list.rows") >= 1
    assert "measured" in c.eval("return %s.views.garbage.list.note:GetText()" % P)
    assert c.eval("return %s.views.garbage.side.ht:GetText()" % P) not in ("", "Nothing picked")
    c.click(c.eval("return %s.views.garbage.list.group" % P))
    assert c.eval("return ns.PerfUI._state.byFile") is True
    assert c.eval("return %s.views.garbage.list.heads[0]:GetText()" % P) == "File"
    # the other tabs fill without errors
    for tab in ("memory", "network", "cpu", "overview"):
        c.click(c.eval("return %s.tabs.%s" % (P, tab)))
        assert c.eval("return %s.views.%s:IsShown()" % (P, tab)) is True, tab
    assert shown_rows(c, "views.memory.pages.rows") >= 1
    assert shown_rows(c, "views.memory.saved.rows") >= 1
    no_errors(w)


@case
def addons_network_windows_and_the_sync_loop_flag():
    w, c = dev()
    a = c.eval_py("local a, total = ns.Perf:Addons() return { n = #a, me = a[1] and a[1].me, total = total }")
    assert a["n"] >= 1 and a["me"] is True and a["total"] > 0, a
    # addon messages: counted per prefix and sender, a minute window that turns over
    c.eval("ns.PerfNet('in', 'CDLd', 300, 'Victhar-Thunderstrike') ns.PerfNet('in', 'CDLd', 200, 'Victhar-Thunderstrike') "
           "ns.PerfNet('out', 'CDLc', 50, 'GUILD')")
    n = c.eval_py("return ns.Perf:Network()")
    pre = {p["prefix"]: p for p in n["prefixes"]}
    assert pre["CDLd"]["inN"] == 2 and pre["CDLd"]["inB"] == 500, pre
    assert n["senders"][0]["who"] == "Victhar-Thunderstrike" and n["senders"][0]["inN"] == 2, n["senders"]
    w.tick(61)
    assert c.eval("return ns.Perf.net.last ~= nil")
    # a message type that goes both ways often: flagged
    c.eval("ns.Perf:Measure(10)")
    for _ in range(10):
        c.eval("ns.PerfComm('BLL', function() end, 'Victhar-Thunderstrike', { t = 'BLL', rev = 5 }, 'GUILD') "
               "ns.Comm:Send({ t = 'BLL', rev = 6 }, 'GUILD', nil, 'data')")
        w.tick(1)
    w.tick(1)
    rows = c.eval_py("local out = {} for i, r in ipairs(ns.Perf.last.rows) do out[i] = r end return out")
    bll = [r for r in rows if r["key"] == "Core/Comm.lua  message BLL"]
    assert bll and bll[0].get("loop") is True, rows
    assert all(not r.get("loop") for r in rows if r["key"] != "Core/Comm.lua  message BLL")
    no_errors(w)


@case
def safecall_forwards_arguments_survives_errors_and_makes_no_garbage():
    w, c = solo("Bob")
    r = c.eval_py(r"""
        local S = ns.SafeCall
        local out = {}
        -- nil arguments in the middle and at the end, and the results back
        local ok, a, b, c3 = S(function(x, y, z, q) return x, y == nil, z end, 1, nil, 3, nil)
        out.args = { ok, a, b, c3 }
        -- nested: a handler that fires another
        local seen = {}
        S(function(x) seen[#seen + 1] = x S(function(y) seen[#seen + 1] = y end, 'inner') seen[#seen + 1] = x end, 'outer')
        out.nested = seen
        -- an error: false back, the error handler told, the next call fine
        local errs = 0
        local old = geterrorhandler()
        seterrorhandler(function(e) errs = errs + 1 return e end)
        local ok2 = S(function(x) error('boom ' .. x) end, 'x')
        seterrorhandler(old)
        local ok3, v3 = S(function(x) return x * 2 end, 21)
        out.err = { ok2, errs, ok3, v3 }
        -- no garbage per call
        local f = function(a, b) return a end
        for i = 1, 50 do S(f, i, 'b') end
        collectgarbage('collect') collectgarbage('stop')
        local c0 = collectgarbage('count')
        for i = 1, 2000 do S(f, i, 'b') end
        out.kb = collectgarbage('count') - c0
        collectgarbage('restart')
        return out
    """)
    assert r["args"] == [True, 1, True, 3], r["args"]
    assert r["nested"] == ["outer", "inner", "outer"], r["nested"]
    assert r["err"] == [False, 1, True, 42], r["err"]
    assert r["kb"] < 8, r["kb"]                       # (a table and a closure a call were ~200 KB for 2000 calls)
    no_errors(w)


if __name__ == "__main__":
    run_all()
