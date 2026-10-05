"""The 3D render probe (/dz 3d probe, Render3D/Probe.lua) on the real addon.

Covers: arming saves probe3d.pending = "armed" and asks for a reload, nothing loose loaded yet; the reloaded UI runs
the probe ("running" in memory only while it runs), loads every loose test model by path, records the build, the
method dumps, what the client says of each file and the projection depths into DisasterZoneDB.probe3d.results, prints
a summary and clears the flag; one more reload saves it all without a crash notice; reset clears only a crash notice or
an armed run (results and history stay), clear forgets everything; safe mode runs at once and loads no loose file and
makes no OffScreenFrame / UiCamera; a login that finds the flag armed without being that reload (the game crashed)
records the crash, loads nothing loose by itself, and plain /dz 3d probe then refuses to arm until reset, while
"only <key>" still bisects (the notice stays, the history keeps each run's verdicts); an armed probe whose reload comes
too late counts as not finished too; only <key> loads that one file, only frames makes the two frame types alone; a
Lua error in a page build reaches the error handler with its stack and the run still finishes; no saved number is NaN
or infinite, even when the client answers with one; every page builds (the depth tiles' cube moved aside, the loose
table in two columns, the cube before you sized to your model, the frame-buffer tiles), the rotation tile's Signs and
Orders buttons turn, and a cost button records its numbers with plain actors; unused, the probe makes nothing.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_probe.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, no_errors, solo, install_helpers, strip_codes  # noqa: E402
import harness  # noqa: E402

PROBE = "Render3D/Probe.lua"
DIR = "Interface\\AddOns\\DisasterZone\\Media\\Probe\\"
FILES = ["probe_copy.m2", "probe_box_md21.m2", "probe_box_noskin.m2", "probe_box_md20.m2", "probe_checker.m2",
         "probe_depth.m2"]
KEYS = ["copy", "md21", "noskin", "md20", "checker", "depth"]
# (a full run leaves out the two layouts no client file has - an MD21 without SFID, a plain MD20 - each loads alone)
RISKY = ["noskin", "md20"]
FULL = [(k, f) for k, f in zip(KEYS, FILES) if k not in RISKY]

# Until the coordinator adds the TOC line, the suite loads the probe where it will sit: after the Render3D files,
# before the UI.
_parse_toc = harness.parse_toc


def _toc_with_probe(addon_dir, addon_name=harness.ADDON_NAME):
    headers, files = _parse_toc(addon_dir, addon_name)
    if PROBE not in files:
        anchor = "Render3D/Rooms.lua" if "Render3D/Rooms.lua" in files else "Render3D/View.lua"
        i = files.index(anchor) + 1
        files = files[:i] + [PROBE] + files[i:]
    return headers, files


harness.parse_toc = _toc_with_probe

# The mock's actors have no SetModelByPath / GetModelPath / SetModelByUnit: a spy adds them (every runtime of the
# client, before the addon loads) and lists the paths asked for. "You" load as display 10001: a model 1.7 yd tall.
SPY = r"""
__PROBE_PATHS = {}
local sc = CreateFrame("ModelScene")
local idx = getmetatable(sc:CreateActor()).__index
idx.SetModelByPath = function(self, path)
  __PROBE_PATHS[#__PROBE_PATHS + 1] = path
  self.probePath = path
  return true
end
idx.GetModelPath = function(self) return self.probePath end
idx.SetModelByUnit = function(self, unit) return self:SetModelByCreatureDisplayID(10001) end
"""
ME_HEIGHT = 1.7

# A client that answers with NaN and infinities: md21's box, the checker's file id, every projection depth. Its model
# paths come back in lower case with forward slashes.
NAN_SPY = SPY + r"""
local box = idx.GetActiveBoundingBox
idx.GetActiveBoundingBox = function(self, ...)
  if self.probePath and self.probePath:find("md21", 1, true) then return 0 / 0, 0, 0, 1 / 0, 1, 2 end
  return box(self, ...)
end
local fid = idx.GetModelFileID
idx.GetModelFileID = function(self, ...)
  if self.probePath and self.probePath:find("checker", 1, true) then return -1 / 0 end
  return fid(self, ...)
end
idx.GetModelPath = function(self) return self.probePath and (self.probePath:lower():gsub("\\", "/")) end
local ms = __MOCK.Methods.ModelScene
local proj = ms.Project3DPointTo2D
ms.Project3DPointTo2D = function(self, x, y, z)
  local px, py = proj(self, x, y, z)
  return px, py, 0 / 0
end
"""


def boot(spy=SPY):
    w, c = solo(preload_lua=spy)
    install_helpers(c)
    return w, c


def state(c):
    return c.eval_py("return DisasterZoneDB.probe3d")


def paths(c):
    return c.eval_py("return __PROBE_PATHS") or []


def reload_requested(c):
    return c.eval("return __MOCK.reload_requested") is True


def chat_since(c, n0):
    return [strip_codes(str(x)) for x in c.chat_frame[n0:]]


def crash(w, c, offline=30):
    """The game crashes: nothing is saved; a fresh start and login later."""
    c._shutdown(save=False)
    c.online = False
    w._sync(roster_changed=True)
    w.tick(offline)
    c.login()
    install_helpers(c)


def not_finite(v, path="results"):
    """Every number in v (nested dicts / lists) that is NaN or infinite, as 'path = value'."""
    out = []
    if isinstance(v, bool):
        return out
    if isinstance(v, (int, float)):
        if not math.isfinite(v):
            out.append("%s = %r" % (path, v))
    elif isinstance(v, dict):
        for k, x in v.items():
            out.extend(not_finite(x, "%s.%s" % (path, k)))
    elif isinstance(v, (list, tuple)):
        for i, x in enumerate(v):
            out.extend(not_finite(x, "%s[%d]" % (path, i + 1)))
    return out


# ------------------------------------------------------------------------------------------------------------------
@case
def arming_reloads_then_the_reload_runs_the_probe_and_records_everything():
    w, c = boot()
    assert c.slash("/dz 3d probe loose confirm")
    assert reload_requested(c)
    st = state(c)
    assert st["pending"] == "armed" and st.get("armedAt"), st
    assert paths(c) == []                                    # (nothing loose before the guarded reload)
    c.relog(reload=True)
    install_helpers(c)
    w.tick(0.5)
    assert state(c)["pending"] == "running"                  # (memory only: the disk still says "armed")
    assert c.eval("return ns.Render3D.Probe.res == nil")     # (the run starts a second after entering the world)
    w.tick(1.0)
    assert sorted(paths(c)) == sorted(DIR + f for _, f in FULL), paths(c)
    assert c.eval("return DisasterZoneProbe3D:IsShown()") is True
    n0 = len(c.chat_frame)
    w.tick(6)
    st = state(c)
    assert st.get("pending") is None, st.get("pending")
    res = st["results"]
    assert res["finished"] is True and res["mode"] == "full", res
    assert res["errors"] == [], res["errors"]
    assert res["build"] == "2.5.6.69795", res["build"]
    # what the client said of each file
    for key, f in FULL:
        r = res["loose"][key]
        assert r["path"] == DIR + f and r["set"] is True, (key, r)
        assert r["loaded2s"] in (True, False) and r["loaded6s"] in (True, False), (key, r)   # (never "error")
        assert r["modelPath"] == DIR + f, (key, r)
    for key in RISKY:
        assert res["loose"][key]["skipped"] == "riskier layout: /dz 3d probe only " + key, res["loose"][key]
    assert res["loose"]["control"]["set"] is True and res["loose"]["control"]["loaded6s"] is False
    # panel 0 / 7: method dumps, the fresh scene's flag, the projection depths
    assert "SetModelByPath" in res["methods"]["ModelSceneActor"].split(), res["methods"]["ModelSceneActor"][:200]
    assert res["create"]["OffScreenFrame"].startswith("no:"), res["create"]   # (the mock has no such frame type)
    assert "overlapDefault" in res
    assert res["pitchSign"] == 1                             # (the mock's camera: a positive pitch looks down)
    assert len(res["depth"]) == 25 and all(isinstance(d["depth"], (int, float)) for d in res["depth"]), res["depth"][:3]
    near = [d for d in res["depth"] if d["near"] == 0.5 and d["far"] == 500]
    assert [d["dist"] for d in near] == [1, 5, 10, 30, 100]
    lines = chat_since(c, n0)
    assert any("3D probe results" in x for x in lines), lines
    assert any("Models: control" in x for x in lines), lines
    assert any("/reload once" in x and "_anniversary_\\Logs" in x for x in lines), lines
    assert not any("IsKnownFile false" in x for x in lines), lines           # (the mock knows every file)
    h = st["history"][-1]
    assert h["finished"] is True
    assert set(h["loose"]) == set(KEYS + ["control"]) and h["loose"]["copy"].startswith("not loaded"), h
    assert h["create"]["UiCamera"].startswith("no:"), h
    no_errors(w)
    # the reload that saves it: no notice, nothing run again
    n1 = len(c.chat_frame)
    c.relog(reload=True)
    w.tick(8)
    st = state(c)
    assert st.get("pending") is None and not st.get("crashed"), st
    assert st["results"]["finished"] is True
    assert paths(c) == []
    assert not any("never finished" in x for x in chat_since(c, n1))
    no_errors(w)


@case
def reset_clears_the_notice_and_an_armed_run_but_keeps_the_results_clear_forgets_everything():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    assert state(c)["results"]["finished"] is True
    c.slash("/dz 3d probe reset")
    st = state(c)
    assert st["results"]["finished"] is True and len(st["history"]) == 1, st
    assert c.eval("return DisasterZoneProbe3D:IsShown()") is False
    # armed, then reset before the reload: the reload runs nothing
    c.relog(reload=True)
    c.slash("/dz 3d probe loose confirm")
    assert state(c)["pending"] == "armed"
    c.slash("/dz 3d probe reset")
    st = state(c)
    assert st.get("pending") is None and st.get("armedAt") is None and len(st["history"]) == 1, st
    c.relog(reload=True)
    w.tick(8)
    assert paths(c) == [] and c.eval("return ns.Render3D.Probe.res == nil")
    assert state(c)["results"]["mode"] == "safe"
    # clear forgets it all
    c.slash("/dz 3d probe clear")
    assert state(c) is None
    no_errors(w)


@case
def safe_mode_runs_at_once_and_loads_no_loose_file():
    w, c = boot()
    n0 = len(c.chat_frame)
    c.slash("/dz 3d probe safe")
    assert not reload_requested(c)
    w.tick(7)
    st = state(c)
    assert st.get("pending") is None
    res = st["results"]
    assert res["mode"] == "safe" and res["finished"] is True, res
    assert paths(c) == []
    for key in KEYS:
        assert res["loose"][key]["skipped"] == "safe mode", (key, res["loose"][key])
        assert "set" not in res["loose"][key]
    assert res["loose"]["control"]["set"] is True             # (Blizzard's cube by file id still loads)
    # the two frame types only in a guarded run
    assert res["create"] == {"OffScreenFrame": "not asked (safe mode)", "UiCamera": "not asked (safe mode)"}, \
        res["create"]
    assert "OffScreenFrame" not in res["counts"]
    assert any("3D probe results" in x for x in chat_since(c, n0))
    # the loose tiles say so
    assert c.find_text("skipped: safe mode"), "tile data lines"
    no_errors(w)


@case
def a_safe_run_closes_the_addons_other_3d_views_first():
    w, c = boot()
    c.eval("ns.MainFrame:Open()")
    assert c.eval("return ns.MainFrame:IsShown()") is True
    n0 = len(c.chat_frame)
    c.slash("/dz 3d probe safe")
    assert c.eval("return ns.MainFrame:IsShown()") is False
    assert any("closed the DisasterZone window" in x for x in chat_since(c, n0)), chat_since(c, n0)
    w.tick(7)
    no_errors(w)


@case
def a_crash_during_the_run_is_recorded_and_nothing_loose_loads_again_by_itself():
    w, c = boot()
    c.slash("/dz 3d probe loose confirm")
    c.relog(reload=True)
    w.tick(1.5)
    assert len(paths(c)) == len(FULL)                         # the run is loading the files ... and the game dies
    crash(w, c)
    n0 = len(c.chat_frame)
    w.tick(8)
    st = state(c)
    assert st["crashed"] is True and st.get("pending") is None, st
    assert st["crash"]["state"] == "armed" and st["crash"]["armedAt"], st["crash"]
    assert st["history"][-1]["finished"] is False
    assert paths(c) == []
    assert c.eval("return ns.Render3D.Probe.res == nil")
    lines = chat_since(c, n0)
    assert any("never finished" in x for x in lines), lines
    assert any("/dz 3d probe - every test" in x and "only <copy/md21/noskin/md20/checker/depth/frames> confirm" in x
               for x in lines), lines
    # plain /dz 3d probe refuses to arm again; safe mode still runs; reset lets it arm
    c.slash("/dz 3d probe loose confirm")
    assert not reload_requested(c) and state(c).get("pending") is None
    c.slash("/dz 3d probe safe")
    w.tick(7)
    assert paths(c) == [] and state(c)["results"]["mode"] == "safe"
    # the crash notice is kept across a clean reload until reset
    c.relog(reload=True)
    w.tick(1)
    assert state(c)["crashed"] is True
    c.slash("/dz 3d probe reset")
    st = state(c)
    assert not st.get("crashed") and not st.get("crash"), st
    assert [h["finished"] for h in st["history"]] == [False, True], st["history"]   # (reset keeps the history)
    c.slash("/dz 3d probe loose confirm")
    assert reload_requested(c) and state(c)["pending"] == "armed"
    no_errors(w)


@case
def only_after_a_crash_bisects_one_file_at_a_time_and_keeps_the_crash_notice():
    w, c = boot()
    c.slash("/dz 3d probe loose confirm")
    c.relog(reload=True)
    w.tick(1.5)
    crash(w, c)
    w.tick(8)
    assert state(c)["crashed"] is True
    # what the notice tells the user to do next: only <key> is allowed and runs
    c.slash("/dz 3d probe only copy confirm")
    st = state(c)
    assert reload_requested(c) and st["pending"] == "armed" and st["only"] == "copy", st
    c.relog(reload=True)
    install_helpers(c)
    w.tick(8)
    assert paths(c) == [DIR + "probe_copy.m2"], paths(c)
    st = state(c)
    assert st.get("pending") is None and st.get("only") is None, st
    assert st["crashed"] is True                              # (the bisect goes on: the notice stays until reset)
    res = st["results"]
    assert res["only"] == "copy" and res["finished"] is True and res["loose"]["copy"]["set"] is True, res
    # the next file replaces the results; the history keeps both runs' verdicts
    c.relog(reload=True)
    c.slash("/dz 3d probe only md21 confirm")
    c.relog(reload=True)
    w.tick(8)
    st = state(c)
    assert st["results"]["only"] == "md21" and st["crashed"] is True
    last = st["history"][-2:]
    assert [h.get("only") for h in last] == ["copy", "md21"], st["history"]
    assert last[0]["loose"]["copy"].startswith("not loaded") and last[0]["loose"]["md21"] == "skipped", last[0]
    assert last[1]["loose"]["md21"].startswith("not loaded") and last[1]["loose"]["copy"] == "skipped", last[1]
    no_errors(w)


@case
def an_armed_probe_whose_reload_comes_too_late_counts_as_not_finished():
    w, c = boot()
    c.slash("/dz 3d probe loose confirm")
    w.tick(700)                                               # (the reload never came in time)
    c.relog(reload=True)
    w.tick(8)
    st = state(c)
    assert st["crashed"] is True and paths(c) == [], st
    # a reload in the middle of a run: "running" reached the disk
    c.slash("/dz 3d probe reset")
    c.slash("/dz 3d probe loose confirm")
    c.relog(reload=True)
    w.tick(1.5)
    assert state(c)["pending"] == "running"
    c.relog(reload=True)
    w.tick(8)
    st = state(c)
    assert st["crashed"] is True and st["crash"]["state"] == "running", st
    no_errors(w)


@case
def only_loads_the_one_file_asked_for():
    w, c = boot()
    n0 = len(c.chat_frame)
    c.slash("/dz 3d probe only nothing")
    assert not reload_requested(c) and state(c) is None
    assert any("one loose model file per run" in x for x in chat_since(c, n0))
    c.slash("/dz 3d probe only md21 confirm")
    assert state(c)["only"] == "md21"
    c.relog(reload=True)
    w.tick(8)
    assert paths(c) == [DIR + "probe_box_md21.m2"], paths(c)
    res = state(c)["results"]
    assert res["only"] == "md21" and res["finished"] is True
    assert res["loose"]["md21"]["set"] is True
    assert res["loose"]["md20"]["skipped"] == "only md21 this run"
    assert res["create"]["OffScreenFrame"] == "not asked (only md21 this run)", res["create"]
    st = state(c)
    assert st.get("pending") is None and st.get("only") is None
    no_errors(w)


@case
def only_frames_makes_the_two_frame_types_alone_in_a_guarded_run():
    w, c = boot()
    n0 = len(c.chat_frame)
    c.slash("/dz 3d probe only frames confirm")
    assert reload_requested(c) and state(c)["only"] == "frames"
    assert any("OffScreenFrame and UiCamera frames only" in x for x in chat_since(c, n0)), chat_since(c, n0)
    c.relog(reload=True)
    install_helpers(c)
    w.tick(8)
    assert paths(c) == []                                     # (no loose file at all)
    st = state(c)
    res = st["results"]
    assert res["only"] == "frames" and res["finished"] is True and st.get("pending") is None, st
    assert res["create"]["OffScreenFrame"].startswith("no:") and res["create"]["UiCamera"].startswith("no:"), \
        res["create"]
    for key in KEYS:
        assert res["loose"][key]["skipped"] == "only frames this run", (key, res["loose"][key])
    assert "OffScreenFrame and UiCamera" in c.eval("return ns.Render3D.Probe.status:GetText()")
    no_errors(w)


@case
def an_error_in_a_page_build_is_reported_with_its_stack_and_the_run_still_finishes():
    w, c = boot()
    c.slash("/dz 3d probe loose confirm")
    c.relog(reload=True)
    install_helpers(c)
    # every tile's edges fail: page 1 cannot build
    c.eval("ns.UI.AddEdges = function() error('probe test: a broken tile') end")
    w.tick(8)
    st = state(c)
    res = st["results"]
    assert res["finished"] is True and st.get("pending") is None, st
    assert any(e.startswith("page 1: ") and "a broken tile" in e for e in res["errors"]), res["errors"]
    assert st["history"][-1]["errors"] >= 1
    # BugSack gets the stack where it happened (the tile builder), not only the step that caught it
    errs = [e for e in w.errors() if "a broken tile" in e]
    assert errs and "Tile" in errs[0], errs
    no_errors(w, allow=("probe test: a broken tile",))


@case
def no_saved_number_is_nan_or_infinite_even_when_the_client_answers_with_one():
    w, c = boot(NAN_SPY)
    c.slash("/dz 3d probe loose confirm")
    c.relog(reload=True)
    install_helpers(c)
    w.tick(8)
    st = state(c)
    res = st["results"]
    assert res["finished"] is True and res["errors"] == [], res["errors"]
    bad = not_finite(st, "probe3d")
    assert bad == [], bad
    # the client's answers are kept, as text
    md21 = res["loose"]["md21"]
    assert md21.get("active") is None and "inf" in md21["activeBad"].lower(), md21
    assert isinstance(res["loose"]["checker"]["modelFileID"], str), res["loose"]["checker"]
    assert all(isinstance(d["depth"], str) for d in res["depth"]), res["depth"][:3]
    # the loose table shows them without a format error; a path that only differs in case and slashes is not shown
    c.eval("ns.Render3D.Probe.SetPage(1)")
    w.tick(0.2)
    right = c.eval("return ns.Render3D.Probe.looseCols[2].fs:GetText()")
    left = c.eval("return ns.Render3D.Probe.looseCols[1].fs:GetText()")
    assert "md21:" in left and "box " in left, left
    assert ", path " not in left + right, left + right
    no_errors(w)


@case
def plain_probe_runs_safe_and_loose_files_need_confirm():
    # loose model files drew a placeholder and, loaded again after a reload, crashed the game (2026-10-05): plain
    # /dz 3d probe runs at once without them; "loose" / "only <key>" without "confirm" only warn
    w, c = boot()
    c.slash("/dz 3d probe loose")
    c.slash("/dz 3d probe only md21")
    st = state(c)
    assert not (st and st.get("pending")), st
    assert sum("crashed the game" in str(x) for x in c.chat_frame[-4:]) == 2, c.chat_frame[-4:]
    c.slash("/dz 3d probe")
    w.tick(7)
    st = state(c)
    assert st["results"]["mode"] == "safe" and st["results"]["finished"] is True, st["results"]
    assert paths(c) == [], paths(c)
    no_errors(w)


@case
def every_page_builds_and_the_cost_buttons_record_their_numbers():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    counts = {}
    for i in range(1, 6):
        c.eval("ns.Render3D.Probe.SetPage(...)", i)
        w.tick(0.2)
        counts[i] = c.eval("return #ns.Render3D.Probe.pages[...].tiles", i)
        assert c.eval("return ns.Render3D.Probe.pages[...]:IsShown()", i) is True
    assert counts == {1: 8, 2: 11, 3: 12, 4: 9, 5: 0}, counts
    # the tiles are numbered 1-40 without gaps (41 is the cost page)
    nums = c.eval_py("local out = {} for _, pg in ipairs(ns.Render3D.Probe.pages) do "
                     "for _, t in ipairs(pg.tiles) do out[#out + 1] = t.n end end return out")
    assert sorted(nums) == list(range(1, 41)), nums
    # page 1: the loose table in two columns
    cols = c.eval_py("local out = {} for i, col in ipairs(ns.Render3D.Probe.looseCols) do "
                     "out[i] = col.fs:GetText() end return out")
    assert len(cols) == 2 and cols[0].startswith("control:") and "noskin:" in cols[0], cols
    assert cols[1].startswith("md20:") and "depth:" in cols[1], cols
    # tiles 7 and 8: the big cube moved sideways by half its width (8 yd cube, 4 yd square seen from above)
    pos = c.eval_py("local a = ns.Render3D.Probe.depthTiles[1].cube local s = a:GetScale() "
                    "local x, y, z = a:GetPosition() return { x * s, y * s, z * s, s }")
    assert abs(pos[3] - 8) < 1e-6 and abs(pos[1] - 6) < 1e-6, pos
    # pages 2 and 3: the cube before you is sized to your model once it has loaded (17 tiles with you and a cube)
    sized = c.eval("local n = 0 for _, a in ipairs(__MOCK.mock_actors) do "
                   "if a.fileID == 167145 and math.abs((a.scale or 1) - 0.25 * ...) < 1e-6 then n = n + 1 end end "
                   "return n", ME_HEIGHT)
    assert sized == 17, sized
    # tiles 30, 31: the frame buffer frames
    fb = c.eval_py("local pg = ns.Render3D.Probe.pages[3] return { pg.tiles[11].n, pg.tiles[11].data:GetText(), "
                   "pg.tiles[12].n }")
    assert fb[0] == 30 and fb[2] == 31 and "SetIsFrameBuffer ok" in fb[1], fb
    assert state(c)["results"]["frameBuffer"]["SetIsFrameBuffer"] == "ok"
    # the rotation tile's dots: 6 orders x 8 corners, its Signs and Orders buttons turn
    t38 = "ns.Render3D.Probe.pages[4].tiles[7]"
    assert c.eval("return %s.n" % t38) == 38
    assert c.eval("return #%s.dots" % t38) == 48
    shown = "local n = 0 for _, d in ipairs(%s.dots) do if d:IsShown() then n = n + 1 end end return n" % t38
    assert c.eval(shown) == 48
    assert c.eval("return ns.Render3D.Probe.signs") == 1
    c.click(c.eval("return %s.signs" % t38))
    assert c.eval("return ns.Render3D.Probe.signs") == 2
    assert c.eval("return %s.signs:GetText()" % t38) == "Signs y- p+ r+"
    assert "yaw -" in c.eval("return %s.data:GetText()" % t38)
    c.click(c.eval("return %s.order" % t38))
    assert c.eval("return ns.Render3D.Probe.order") == 1
    assert c.eval("return %s.order:GetText()" % t38) == "Order Y.P.R"
    assert c.eval(shown) == 8
    for _ in range(6):
        c.click(c.eval("return %s.order" % t38))
    assert c.eval("return ns.Render3D.Probe.order") == 0 and c.eval(shown) == 48
    # the cost page: 250 cubes, then their numbers
    c.eval("ns.Render3D.Probe.SetPage(5)")
    w.tick(0.1)
    n0 = len(c.chat_frame)
    b = c.eval("return T_button(ns.Render3D.Probe.pages[5], '250 cubes')")
    assert b is not None
    c.click(b)
    w.tick(4)
    cost = state(c)["results"]["cost"]["250"]
    assert cost["n"] == 250 and cost["made"] == 250 and cost["fpsAfter"] == 60, cost
    assert c.eval("return #ns.Render3D.Probe.pages[5].pool") == 250
    # (plain actors: no template, so no Lua OnUpdate of their own in the numbers)
    assert c.eval("local n = 0 for _, a in ipairs(ns.Render3D.Probe.pages[5].pool) do "
                  "if a.template then n = n + 1 end end return n") == 0
    assert any("250 paused cubes" in x for x in chat_since(c, n0))
    # fewer again reuses the actors
    c.click(c.eval("return T_button(ns.Render3D.Probe.pages[5], 'Clear')"))
    no_errors(w)


@case
def unused_the_probe_makes_nothing():
    w, c = boot()
    w.tick(3)
    assert c.eval("return ns.Render3D.Probe ~= nil")
    assert c.eval("return ns.Render3D.Probe.win == nil and ns.Render3D.Probe.res == nil")
    assert c.eval("return DisasterZoneProbe3D == nil")
    assert state(c) is None
    c.relog(reload=True)
    w.tick(3)
    assert state(c) is None and c.eval("return ns.Render3D.Probe.win == nil")
    no_errors(w)


run_all()
