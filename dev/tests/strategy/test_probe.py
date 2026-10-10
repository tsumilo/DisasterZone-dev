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

Round 3: the flag and alpha pages open in solo - only one tile's scenes shown (every other scene of the probe hidden,
on every page and outside the window, the measuring scene too), the other captions greyed, Prev / Next / All tiles in
the bar under the page, each page remembering its tile; the flag tiles flag exactly the scenes their captions name
(lower, upper, both, an empty middle scene, one with a cube aside, one only a corner square); the alpha page tests
each alpha in a lower scene and in your own; tile 14 keeps its teal frame (left half) between the scenes inside the
clipping frame and tile 42 outside it; tile 38 frames every candidate corner and outlines one order at a time, its
dots on its own scene, every wrong order missing a visible corner by about 40 px in the tile's own view; the
flat-model page is built only when its tab is opened (the run loads none of its stock models), shows each stand-in
candidate turned about one axis with its outline (52 from below), the stand-ins with 59's control at 51's scale, and
records the client's box 2 and 6 s after it was built; and every FileDataID the probe hands SetModelByFileID is an M2
file of the installed client, each candidate passing find_flat_prims.py but the two controls.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_probe.py [-k name]
"""
import math
import os
import re
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
    if PROBE not in files and addon_name == harness.ADDON_NAME:      # (not DisasterZone_Rooms' TOC)
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
-- every file ID asked for, and the turns the mock's actors lack
__PROBE_FIDS = {}
local byFile = idx.SetModelByFileID
idx.SetModelByFileID = function(self, id, ...)
  __PROBE_FIDS[id] = (__PROBE_FIDS[id] or 0) + 1
  return byFile(self, id, ...)
end
idx.SetPitch = function(self, v) self.pitch = v end
idx.SetRoll = function(self, v) self.roll = v end
-- the scenes flagged with SetAllowOverlappedModels(true)
__PROBE_FLAGS = setmetatable({}, { __mode = "k" })
local msm = __MOCK.Methods.ModelScene
msm.SetAllowOverlappedModels = function(self, v) __PROBE_FLAGS[self] = v and true or false end
msm.GetAllowOverlappedModels = function(self) return __PROBE_FLAGS[self] or false end
"""
ME_HEIGHT = 1.7
# The stand-in candidates of page 6 (find_flat_prims.py) and Blizzard's unit cube: all the probe may load by file ID.
PRIM_FIDS = {198111, 198110, 653518, 1396283, 200893, 219357, 203154}
CUBE = 167145

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


def res_errors(c):
    return state(c)["results"]["errors"]


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
    assert errs and any("in function 'Tile'" in e for e in errs), errs
    # (the solo bar's buttons fail the same way: the window still opened)
    assert any(e.startswith("bar: ") for e in res["errors"]), res["errors"]
    assert c.eval("return DisasterZoneProbe3D:IsShown()") is True
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
    for i in range(1, 8):
        c.eval("ns.Render3D.Probe.SetPage(...)", i)
        w.tick(0.2)
        counts[i] = c.eval("return #ns.Render3D.Probe.pages[...].tiles", i)
        assert c.eval("return ns.Render3D.Probe.pages[...]:IsShown()", i) is True
    assert counts == {1: 8, 2: 12, 3: 12, 4: 8, 5: 9, 6: 11, 7: 0}, counts
    assert res_errors(c) == [], res_errors(c)
    # the tiles are numbered 1-61 without gaps but 41 (the cost page); round 2's numbers kept their meaning
    nums = c.eval_py("local out = {} for _, pg in ipairs(ns.Render3D.Probe.pages) do "
                     "for _, t in ipairs(pg.tiles) do out[#out + 1] = t.n end end return out")
    assert sorted(nums) == [n for n in range(1, 62) if n != 41], nums
    # page 1: the loose table in two columns
    cols = c.eval_py("local out = {} for i, col in ipairs(ns.Render3D.Probe.looseCols) do "
                     "out[i] = col.fs:GetText() end return out")
    assert len(cols) == 2 and cols[0].startswith("control:") and "noskin:" in cols[0], cols
    assert cols[1].startswith("md20:") and "depth:" in cols[1], cols
    # tiles 7 and 8: the big cube moved sideways by half its width (8 yd cube, 4 yd square seen from above)
    pos = c.eval_py("local a = ns.Render3D.Probe.depthTiles[1].cube local s = a:GetScale() "
                    "local x, y, z = a:GetPosition() return { x * s, y * s, z * s, s }")
    assert abs(pos[3] - 8) < 1e-6 and abs(pos[1] - 6) < 1e-6, pos
    # pages 2-4: the cube before you is sized to your model once it has loaded (26 tiles with you and a cube)
    sized = c.eval("local n = 0 for _, a in ipairs(__MOCK.mock_actors) do "
                   "if a.fileID == 167145 and math.abs((a.scale or 1) - 0.25 * ...) < 1e-6 then n = n + 1 end end "
                   "return n", ME_HEIGHT)
    assert sized == 26, sized
    # tiles 30, 31: the frame buffer frames
    fb = c.eval_py("local pg = ns.Render3D.Probe.pages[3] return { pg.tiles[11].n, pg.tiles[11].data:GetText(), "
                   "pg.tiles[12].n }")
    assert fb[0] == 30 and fb[2] == 31 and "SetIsFrameBuffer ok" in fb[1], fb
    assert state(c)["results"]["frameBuffer"]["SetIsFrameBuffer"] == "ok"
    # the rotation tile's dots: 6 orders x 8 corners, its Signs and Orders buttons turn
    t38 = "ns.Render3D.Probe.pages[5].tiles[7]"
    assert c.eval("return %s.n" % t38) == 38
    assert c.eval("return #%s.dots" % t38) == 48
    shown = "local n = 0 for _, d in ipairs(%s.dots) do if d:IsShown() then n = n + 1 end end return n" % t38
    lines = "local n = 0 for _, l in ipairs(%s.lines or {}) do if l:IsShown() then n = n + 1 end end return n" % t38
    assert c.eval(shown) == 48 and c.eval(lines) == 0
    # (the camera fitted to every candidate corner: each dot inside the scene, the camera farther than round 2's 4.5)
    inside = c.eval_py("local t = %s local sc = t.scenes[1] local w, h = sc:GetWidth(), sc:GetHeight() "
                       "local out = { dist = sc.probeDist, w = w, h = h, out = 0 } "
                       "for _, d in ipairs(t.dots) do local _, _, _, x, y = d:GetPoint(1) "
                       "if x < 0 or x > w or y < 0 or y > h then out.out = out.out + 1 end end return out" % t38)
    assert inside["out"] == 0 and inside["dist"] > 4.5, inside
    assert c.eval("return ns.Render3D.Probe.signs") == 1
    c.click(c.eval("return %s.signs" % t38))
    assert c.eval("return ns.Render3D.Probe.signs") == 2
    assert c.eval("return %s.signs:GetText()" % t38) == "Signs y- p+ r+"
    assert "yaw -" in c.eval("return %s.data:GetText()" % t38)
    c.click(c.eval("return %s.order" % t38))
    assert c.eval("return ns.Render3D.Probe.order") == 1
    assert c.eval("return %s.order:GetText()" % t38) == "Order Y.P.R"
    assert c.eval(shown) == 8 and c.eval(lines) == 12                # (one order: its dots and its outline)
    for _ in range(6):
        c.click(c.eval("return %s.order" % t38))
    assert c.eval("return ns.Render3D.Probe.order") == 0 and c.eval(shown) == 48 and c.eval(lines) == 0
    # the cost page: 250 cubes, then their numbers
    c.eval("ns.Render3D.Probe.SetPage(7)")
    w.tick(0.1)
    n0 = len(c.chat_frame)
    b = c.eval("return T_button(ns.Render3D.Probe.pages[7], '250 cubes')")
    assert b is not None
    c.click(b)
    w.tick(4)
    cost = state(c)["results"]["cost"]["250"]
    assert cost["n"] == 250 and cost["made"] == 250 and cost["fpsAfter"] == 60, cost
    assert c.eval("return #ns.Render3D.Probe.pages[7].pool") == 250
    # (plain actors: no template, so no Lua OnUpdate of their own in the numbers)
    assert c.eval("local n = 0 for _, a in ipairs(ns.Render3D.Probe.pages[7].pool) do "
                  "if a.template then n = n + 1 end end return n") == 0
    assert any("250 paused cubes" in x for x in chat_since(c, n0))
    # fewer again reuses the actors
    c.click(c.eval("return T_button(ns.Render3D.Probe.pages[7], 'Clear')"))
    no_errors(w)


@case
def the_flag_and_alpha_pages_open_in_solo_and_show_one_tiles_scenes_only():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    P = "ns.Render3D.Probe"
    # every scene shown: the tile numbers of the shown scenes (0: the measuring scene), and the scene outside the
    # window (tile 18, MEDIUM strata under UIParent)
    shown = ("local out = {} for _, sc in ipairs(%s.scenes) do if sc:IsShown() then local t = sc.probeTile "
             "out[#out + 1] = t and t.n or 0 end end table.sort(out) return out" % P)
    outer = "for _, sc in ipairs(%s.scenes) do if sc.probeOuter then return sc:IsShown() end end" % P
    bar = P + ".bar"
    # page 1 has no solo: all its scenes, the measuring scene and nothing hidden
    assert c.eval("return %s.solo[1]" % P) is False
    assert c.eval("return %s.measure:IsShown()" % P) is True
    c.eval(P + ".SetPage(3)")
    w.tick(0.6)
    assert c.eval("return %s.solo[3]" % P) == 1 and c.eval("return %s.solo[4]" % P) == 1
    assert c.eval_py(shown) == [20, 20], c.eval_py(shown)                # tile 20's two scenes, nothing else at all
    assert c.eval(outer) is False and c.eval("return %s.measure:IsShown()" % P) is False
    caps = c.eval_py("local out = {} for i, t in ipairs(%s.pages[3].tiles) do local r = t.cap:GetTextColor() "
                     "out[i] = r end return out" % P)
    assert caps[0] == 1 and all(abs(x - 0.4) < 1e-6 for x in caps[1:]), caps
    assert c.eval("return %s.label:GetText()" % bar) == "Solo: tile 20 (1 of 12)"
    assert c.eval("return %s.text:GetText()" % bar).startswith("20. Flag off on both scenes")
    assert c.eval("return %s.mode:GetText()" % bar) == "All tiles"
    # Next, Prev (wrapping round)
    c.click(c.eval("return %s.next" % bar))
    assert c.eval_py(shown) == [21, 21] and c.eval("return %s.solo[3]" % P) == 2
    for _ in range(2):
        c.click(c.eval("return %s.prev" % bar))
    assert c.eval_py(shown) == [31, 31], c.eval_py(shown)
    assert c.eval("return %s.label:GetText()" % bar) == "Solo: tile 31 (12 of 12)"
    # the three-scene tiles show their three scenes
    for _ in range(7):
        c.click(c.eval("return %s.prev" % bar))
    assert c.eval_py(shown) == [43, 43, 43], c.eval_py(shown)
    # another page without solo: every scene shown again (hidden pages' scenes too, by their own flag; 0 = the
    # measuring and cost scenes), the outer one with its page; the remembered tile on return
    c.eval(P + ".SetPage(2)")
    w.tick(0.2)
    on2 = c.eval_py(shown)
    # (not page 6's 51-61: that page is built only when its tab is opened)
    assert sorted(set(on2)) == [0] + [n for n in range(1, 51) if n != 41] and on2.count(18) == 2, on2
    assert c.eval(outer) is True
    assert c.eval("return %s.label:GetText()" % bar) == "All 12 tiles shown"
    c.eval(P + ".SetPage(3)")
    w.tick(0.2)
    assert c.eval_py(shown) == [43, 43, 43] and c.eval(outer) is False
    # All tiles: page 3 draws at once (every probe scene shown again), Solo: back at the same tile
    c.click(c.eval("return %s.mode" % bar))
    assert c.eval("return %s.solo[3]" % P) is False and c.eval("return %s.mode:GetText()" % bar) == "Solo"
    assert len(c.eval_py(shown)) == c.eval("return #%s.scenes" % P) - 1        # (all but tile 18's: page 2 is hidden)
    assert c.eval("local r = %s.pages[3].tiles[2].cap:GetTextColor() return r" % P) == 1
    c.click(c.eval("return %s.mode" % bar))
    assert c.eval_py(shown) == [43, 43, 43]
    # the alpha page starts in solo at its first tile, the lower-scene alpha 1 control
    c.eval(P + ".SetPage(4)")
    w.tick(0.2)
    assert c.eval_py(shown) == [26, 26] and c.eval("return %s.label:GetText()" % bar) == "Solo: tile 26 (1 of 8)"
    # the cost page has no tiles: no stepper, the status stays
    c.eval(P + ".SetPage(7)")
    w.tick(0.1)
    assert c.eval("return %s.prev:IsShown()" % bar) is False
    assert "done - screenshot each page" in c.eval("return %s.status:GetText()" % P)
    no_errors(w)


@case
def the_flag_tiles_flag_exactly_the_scenes_their_captions_name():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    c.eval("ns.Render3D.Probe.SetPage(3)")
    w.tick(0.2)
    got = c.eval_py("local out = {} for _, t in ipairs(ns.Render3D.Probe.pages[3].tiles) do local f = {} "
                    "for j, sc in ipairs(t.scenes or {}) do f[j] = __PROBE_FLAGS[sc] and true or false end "
                    "out[#out + 1] = { t.n, f } end return out")
    got = {n: f for n, f in got}
    F, T = False, True
    want = {20: [F, F], 21: [F, T], 22: [T, F], 23: [T, T],              # lower / upper (you) scene
            43: [F, F, F], 44: [F, T, F], 45: [F, T, F], 46: [F, T, F],  # cube, middle, you
            24: [F, F], 25: [T, T], 30: [F, F], 31: [F, F]}
    assert got == want, got
    # the middle scenes: 43 / 44 empty, 45 a small cube aside, 46 only a 30 px square in the corner
    small = c.eval_py("local out = {} for _, a in ipairs(__MOCK.mock_actors) do "
                      "if a.fileID == 167145 and (a.scale == 0.35 or a.scale == 0.9) then out[#out + 1] = a.scale end "
                      "end table.sort(out) return out")
    assert small == [0.35, 0.9], small
    corner = c.eval_py("local t = ns.Render3D.Probe.pages[3].tiles[8] local m = t.scenes[2] "
                       "return { t.n, m:GetWidth(), m:GetHeight(), (m:GetPoint(1)) }")
    assert corner == [46, 30, 30, "BOTTOMRIGHT"], corner
    # what the flag answered right after it was set (the getter), kept for the summary
    assert state(c)["results"]["overlapSet"] is True
    # the captions say what each outcome means
    caps = c.eval_py("local out = {} for _, t in ipairs(ns.Render3D.Probe.pages[3].tiles) do "
                     "out[t.n] = t.caption .. ' ' .. (t.long or '') end return out")
    assert "clears before drawing" in caps[21] and "own buffer" in caps[21] and "no effect" in caps[21]
    assert "clears before drawing" in caps[22] and "own buffer" in caps[22]
    assert "even empty" in caps[44] and "whole rectangle" in caps[45] and "covers the screen" in caps[46]
    no_errors(w)


@case
def the_alpha_page_tests_each_alpha_in_a_lower_scene_and_in_your_own():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    c.eval("ns.Render3D.Probe.SetPage(4)")
    w.tick(0.2)
    tiles = c.eval_py("local out = {} for _, t in ipairs(ns.Render3D.Probe.pages[4].tiles) do "
                      "out[#out + 1] = { t.n, #t.scenes, t.data:GetText() } end return out")
    assert [t[0] for t in tiles] == [26, 27, 28, 29, 47, 48, 49, 50], tiles
    assert [t[1] for t in tiles] == [2, 2, 2, 2, 1, 1, 1, 1], tiles
    assert tiles[2][2] == "actor alpha 0.01, lower scene" and tiles[6][2] == "actor alpha 0.01, one scene", tiles
    # every alpha twice (lower scene, one scene), on the cube sized to you
    alphas = c.eval_py("local out = {} for _, a in ipairs(__MOCK.mock_actors) do "
                       "if a.fileID == 167145 and a.alpha then out[#out + 1] = a.alpha end end table.sort(out) "
                       "return out")
    assert alphas == [0, 0, 0.01, 0.01, 0.5, 0.5, 1, 1], alphas
    no_errors(w)


@case
def tile_14_keeps_its_teal_frame_between_the_scenes_inside_the_clipping_frame_and_42_outside_it():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    c.eval("ns.Render3D.Probe.SetPage(2)")
    w.tick(0.2)
    for idx, n, inside in ((6, 14, True), (12, 42, False)):
        r = c.eval_py("local t = ns.Render3D.Probe.pages[2].tiles[...] local A, B = t.scenes[1], t.scenes[2] "
                      "return { n = t.n, clips = t.holder:DoesClipChildren(), "
                      "aIn = A:GetParent() == t.holder, bIn = B:GetParent() == t.holder, "
                      "coverIn = t.cover:GetParent() == t.holder, coverArea = t.cover:GetParent() == t.area, "
                      "a = A:GetFrameLevel(), c = t.cover:GetFrameLevel(), b = B:GetFrameLevel(), "
                      "cw = t.cover:GetWidth(), w = t.area:GetWidth() }", idx)
        assert r["n"] == n and r["clips"] is True and r["aIn"] and r["bIn"], r
        assert r["a"] < r["c"] < r["b"], r                                   # (the teal between the two scenes)
        assert r["coverIn"] is inside and r["coverArea"] is (not inside), r
        assert abs(r["cw"] - r["w"] / 2) < 1e-6, r                           # (the left half only)
    no_errors(w)


@case
def the_flat_model_page_shows_each_candidate_turned_about_one_axis_with_its_outline():
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    # the run itself never builds page 6: its stock models load only when its tab is opened (a crash there is pinned
    # on that page, and the other pages stay usable)
    assert c.eval("return ns.Render3D.Probe.pages[6].built") is None
    asked = c.eval_py("local out = {} for k in pairs(__PROBE_FIDS) do out[#out + 1] = k end return out") or []
    assert {int(k) for k in asked} == {CUBE}, asked
    assert "prims" not in state(c)["results"], state(c)["results"].get("prims")
    c.eval("ns.Render3D.Probe.SetPage(6)")
    w.tick(0.6)
    tiles = c.eval_py("local out = {} for _, t in ipairs(ns.Render3D.Probe.pages[6].tiles) do "
                      "out[#out + 1] = { t.n, t.wired or 0, t.dots and t.dots[1] and t.dots[1]:IsShown() or false } "
                      "end return out")
    assert [t[0] for t in tiles] == list(range(51, 62)), tiles
    # the outline: 4 lines for a flat model, 12 for a box, 4 for the stand-ins' quads; the red origin dot
    assert [t[1] for t in tiles] == [4, 4, 4, 4, 4, 4, 12, 12, 4, 4, 4], tiles
    assert all(t[2] for t in tiles[:8]), tiles
    # 51 sees the downward-winding quad from above (the two-sided check), 52 from below: its front, so its
    # header-box answer does not hang on the two-sided flag
    cams = c.eval_py("local out = {} for i = 1, 2 do out[i] = ns.Render3D.Probe.pages[6].tiles[i].scenes[1].probeCam "
                     "end return out")
    assert cams[0][2] > cams[0][5] and cams[1][2] < cams[1][5], cams
    # each candidate by its file ID, scaled so its longest side is 2.4 yd, SetYaw(30 deg) only
    boxes = {198111: 109.1222, 198110: 109.1222, 653518: 48.9308, 1396283: 63.8288, 200893: 1.6827,
             219357: 2.7778, 203154: 3.9398}
    acts = c.eval_py("local out = {} for _, h in ipairs(ns.Render3D.Probe.prims) do "
                     "out[#out + 1] = { h.key, h.fid, h.a.fileID, h.a:GetScale(), h.a.yaw or 0, h.a.pitch or 0 } end "
                     "return out")
    assert [a[0] for a in acts] == [str(n) for n in range(51, 59)], acts
    for key, fid, loaded, scale, yaw, pitch in acts:
        assert loaded == fid and abs(scale - 2.4 / boxes[fid]) < 1e-4, (key, fid, loaded, scale)
        assert abs(yaw - math.radians(30)) < 1e-9 and pitch == 0, (key, yaw, pitch)
    # the stand-ins: 198111 stood up by SetPitch(90 deg), 653518 turned by SetYaw(180 deg), in the lower scene
    turns = c.eval_py("local out = {} for i = 9, 11 do local t = ns.Render3D.Probe.pages[6].tiles[i] "
                      "out[#out + 1] = t.data:GetText() end return out")
    # (sized to you: 0.45 of your 1.7 yd seen at 0.68 of the way to you, over the turned quad's height; the scale
    # shown; 61, the control for 59, at 51's scale instead)
    s59, s60 = 0.45 * ME_HEIGHT * 0.68 / 89.6895, 0.45 * ME_HEIGHT * 0.68 / 32.9853
    assert turns == ["198111: SetPitch 90, scale %.4f" % s59,
                     "653518: SetYaw 180, scale %.4f" % s60,
                     "198111: SetPitch 90, scale %.4f" % (2.4 / 109.1222)], turns
    st = c.eval_py("local out = {} for _, a in ipairs(__MOCK.mock_actors) do "
                   "if a.fileID == 198111 and a.pitch then out[#out + 1] = a.pitch end "
                   "if a.fileID == 653518 and a.yaw and math.abs(a.yaw - math.pi) < 1e-9 then out[#out + 1] = -1 end "
                   "end return out")
    assert sorted(st) == [-1, math.pi / 2, math.pi / 2], st
    # what the client said of each (2 s and 6 s after the page was built), for the summary and the saved results
    assert "prims" not in state(c)["results"]
    w.tick(6)
    res = state(c)["results"]
    assert sorted(res["prims"]) == [str(n) for n in range(51, 59)], res["prims"]
    assert res["prims"]["53"]["fid"] == 653518 and res["prims"]["53"]["loaded"] is False, res["prims"]["53"]
    assert c.eval("return ns.Render3D.Probe.pages[6].tiles[1].data:GetText()").startswith("198111: loaded false")
    assert any(line.startswith("Stand-in candidates (page 6 tiles): 51 (198111)") for line in
               c.eval_py("return ns.Render3D.Probe.SummaryLines(ns.Render3D.Probe.res)"))
    no_errors(w)


@case
def every_file_id_the_probe_loads_is_a_model_file_of_the_installed_client():
    # SetModelByFileID with an ID that is not a model can crash the client (WoWUIBugs #67): the probe may only use
    # Blizzard's unit cube and find_flat_prims.py's candidates, each an M2 of the installed build
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    for i in range(1, 8):
        c.eval("ns.Render3D.Probe.SetPage(...)", i)
        w.tick(0.1)
    asked = {int(k) for k in (c.eval_py("local out = {} for k in pairs(__PROBE_FIDS) do out[#out + 1] = k end "
                                        "return out") or [])}
    assert asked == PRIM_FIDS | {CUBE}, sorted(asked)
    src = open(os.path.join(harness.ADDON_DIR, "Render3D", "Probe.lua"), encoding="utf-8").read()
    named = {int(x) for x in re.findall(r"fid = (\d+)", src)} | {int(x) for x in re.findall(r"CUBE = (\d+)", src)}
    assert named == PRIM_FIDS | {CUBE}, sorted(named)
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "generators"))
        import casc_local
        casc_local.root()
    except Exception as e:                       # (no installed client here: the IDs were checked when picked)
        print("    (installed client not readable, file check skipped: %s)" % e)
        return
    for fid in sorted(asked):
        data = casc_local.read_fid(fid)
        assert data[:4] in (b"MD21", b"MD20"), (fid, data[:4])
    # each candidate still passes find_flat_prims.py (but the two controls: 198110's header box, 200893's projected
    # texture batch), and the mesh box page 6 draws its outline from is the scanner's
    import find_flat_prims
    boxes = {int(f): [float(x) for x in b.split(",")]
             for f, b in re.findall(r"fid = (\d+), box = \{([^}]*)\}", src)}
    for fid in sorted(PRIM_FIDS):
        r = find_flat_prims.analyse(fid)
        want = {198110: ["header box off the mesh by 17.059"],
                200893: ["projected texture batch (flags 0x14)"]}.get(fid, [])
        assert r.get("kind") in ("flat", "box") and r["why"] == want, (fid, r["why"])
        # (tile 56's text: of page 6's candidates only G_Blanket's batch differs - the projected flag, and the
        # alpha key's shader 0x10)
        batch = (["0x14"], ["0x10"]) if fid == 200893 else (["0x10"], ["0x0"])
        assert (r["batchFlags"], r["shaders"]) == batch, (fid, r["batchFlags"], r["shaders"])
        if fid in boxes:
            assert max(abs(a - b) for a, b in zip(boxes[fid], r["mesh"])) < 1e-3, (fid, boxes[fid], r["mesh"])
    assert len(boxes) == len(PRIM_FIDS) - 1, sorted(boxes)          # (198110 shares 198111's box)
    no_errors(w)


@case
def tile_38s_orders_miss_a_visible_corner_by_40_px_in_its_own_view():
    # whichever order is the true one, every wrong order has no dot within about 40 px of some visible corner of the
    # true cube - measured on the dots as drawn, with the tile's own perspective camera (Probe.lua's TURN; the first
    # pick only kept its margin seen from far away)
    w, c = boot()
    c.slash("/dz 3d probe safe")
    w.tick(7)
    c.eval("ns.Render3D.Probe.SetPage(5)")
    w.tick(0.6)
    # (the mock does not size a frame from two anchors: the tile's area and scene get the layout's size, 454 x 276,
    # and the tile draws again - Fit backs the camera off with the mock's pinhole projection, a horizontal lens)
    got = c.eval_py("local t = ns.Render3D.Probe.pages[5].tiles[7] local sc = t.scenes[1] "
                    "t.area:SetWidth(t.f:GetWidth()) sc:SetSize(t.f:GetWidth(), t.area:GetHeight()) t.draw() "
                    "local out = { n = t.n, cam = sc.probeCam, dist = sc.probeDist, w = sc:GetWidth(), "
                    "h = sc:GetHeight(), dots = {}, own = 0 } for i, d in ipairs(t.dots) do "
                    "local _, rel, _, x, y = d:GetPoint(1) out.dots[i] = { x, y } "
                    "if rel == sc then out.own = out.own + 1 end end return out")
    assert got["n"] == 38 and (got["w"], got["h"]) == (454, 276), got
    # every dot on tile 38's own scene (BuildParticles once reused that local for tile 40), inside it, the camera
    # backed off past the first guess
    assert got["own"] == 48, got["own"]
    assert all(0 < x < got["w"] and 0 < y < got["h"] for x, y in got["dots"]), got["dots"]
    assert got["dist"] > 6.5, got["dist"]
    src = open(os.path.join(harness.ADDON_DIR, "Render3D", "Probe.lua"), encoding="utf-8").read()
    body = re.search(r"local TURN = \{([^}]*)\}", src).group(1)
    ang = {k: math.radians(float(v)) for k, v in re.findall(r"(\w) = (\d+)", body)}

    def axis(k, a):
        co, si = math.cos(a), math.sin(a)
        return {"y": [[co, -si, 0], [si, co, 0], [0, 0, 1]], "p": [[co, 0, si], [0, 1, 0], [-si, 0, co]],
                "r": [[1, 0, 0], [0, co, -si], [0, si, co]]}[k]

    def mul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]

    def apply(m, v):
        return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]

    orders = ["ypr", "yrp", "pyr", "pry", "ryp", "rpy"]                 # (Probe.lua's ORDERS, in its order)
    corners = [[1 if i % 2 else -1, 1 if (i // 2) % 2 else -1, 1 if i // 4 else -1] for i in range(8)]
    cam = got["cam"][:3]
    dots = got["dots"]
    assert len(dots) == 48, len(dots)
    worst = None
    for k, true in enumerate(orders):
        m = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for ch in true:
            m = mul(m, axis(ch, ang[ch]))
        # the true cube's visible corners: those of a face turned towards the camera (a 2 yd cube: centre = normal)
        seen = set()
        for ax in range(3):
            for sd in (-1, 1):
                n = apply(m, [sd if i == ax else 0 for i in range(3)])
                if sum(n[i] * (cam[i] - n[i]) for i in range(3)) > 0:
                    seen |= {j for j, cc in enumerate(corners) if cc[ax] == sd}
        for kw in range(len(orders)):
            if kw == k:
                continue
            gap = max(min(math.dist(dots[k * 8 + j], dots[kw * 8 + q]) for q in range(8)) for j in seen)
            worst = gap if worst is None else min(worst, gap)
    assert worst >= 38, worst
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
