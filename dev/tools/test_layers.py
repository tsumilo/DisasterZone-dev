"""Self-test of the layer map + lint (tools/layers.py), the module headers (tools/modules_doc.py), the Lua 5.1 limits
(luabc.limits) and their check.py flags, on small fake addon trees in a temp dir.

Run: luaenv\\Scripts\\python.exe tools\\test_layers.py [-k name]   (~5 s; the last test reads the real addon)
"""
import io
import json
import os
import shutil
import sys
import tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import layers as L  # noqa: E402
import modules_doc as M  # noqa: E402
import uniformity  # noqa: E402

GUARD = 'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s\n'

# A small config shaped like tools/layers.json
CFG = {
    "layers": {"0": "Platform", "1": "Game data", "2": "Context", "3": "Feature logic", "4": "Sync", "5": "UI",
               "6": "Games"},
    "prefixes": {"Core/": 0, "Data/": 1, "Logic/Context/": 2, "Logic/": 3, "Sync/": 4, "UI/": 5, "Games/": 6},
    "files": {"Core/Guild.lua": 2, "Core/RaidPlan.lua": 3, "Core/Loot.lua": 3, "Core/Events.lua": 3,
              "Core/Strategy.lua": 3, "Core/Comm.lua": 4},
    "features": [["^Core/Comm\\.lua$", "Sync"], ["^Core/Guild\\.lua$", "Context"],
                 ["^Core/RaidPlan\\.lua$", "Raids"], ["^Core/Loot\\.lua$", "Loot"],
                 ["^Core/Events\\.lua$", "Events"], ["^Core/Strategy\\.lua$", "Strategy"],
                 ["^UI/(Style|Widgets)\\.lua$", "Kit"], ["^UI/Comp/", "Kit"], ["^UI/Raids\\w*\\.lua$", "Raids"],
                 ["^Logic/(Context|Raids|Loot)/", "\\1"], ["^UI/Kit/", "Kit"],
                 ["^Core/", "Platform"], ["^UI/", "Shell"], ["^Games/", "Games"]],
    "feature_order": [["Context"], ["Raids"], ["Loot"], ["Events", "Strategy"]],
    "logic_layers": [2, 3],
    "kit": {"feature": "Kit", "forbidden": ["Raids", "Loot", "Events", "Strategy", "Shell", "Games"],
            "min_target_layer": 2},
    "wire": {"Comm": "^(Send|Register)"},
}


class Fake:
    """A throwaway addon: Fake(files) writes <tmp>/DisasterZone/{DisasterZone.toc, files...} (TOC in dict order)."""

    def __init__(self, files, cfg=None):
        self.tmp = tempfile.mkdtemp(prefix="dz_layers_")
        self.root = os.path.join(self.tmp, "DisasterZone")
        os.makedirs(self.root)
        self.files = dict(files)
        self.cfg = L.Config(json.loads(json.dumps(cfg or CFG)))
        self.write()

    def write(self):
        with open(os.path.join(self.root, "DisasterZone.toc"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("## Interface: 20506\n## Title: fake\nLibs\\LibStub\\LibStub.lua\n")
            for f in self.files:
                fh.write(f.replace("/", "\\") + "\n")
        for f, src in self.files.items():
            p = os.path.join(self.root, f)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(GUARD % (f, f) + src)

    def build(self):
        return L.build(self.root, self.cfg)

    def path(self, name):
        return os.path.join(self.tmp, name)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def edge(dm, a, b):
    return dm.edges.get((a, b))


def kinds(dm):
    return {(v.kind, v.src, v.dst) for v in L.violations(dm)}


# ---------------------------------------------------------------------------------------------------------------
def test_mask_matches_uniformity_mask():
    src = ('local a = "x--y" .. \'q\\\'s\' -- c "s"\n--[==[ long\n comment ]==] local b = [[ab\ncd]]\n'
           'local c = [=[ ]] ]=] ns.Util.Now() --[[x]] d = "unterminated\nlocal e = 1\n')
    assert L.mask(src) == uniformity.mask(src)
    assert len(L.mask(src)) == len(src) and L.mask(src).count("\n") == src.count("\n")


def test_alias_resolution():
    fk = Fake({
        "Core/Util.lua": 'local Util = ns:NewModule("Util")\nfunction Util.Now() end\nfunction Util:Key() end\n'
                         'Util.LIMIT = 5\n',
        "Core/Other.lua": "local O = {}\nns.Other = O\nfunction O:Go() end\n",
        "Core/A.lua": ("local addonName, ns = ...\n"
                       "local U = ns.Util\n"
                       "local Now = ns.Util.Now\n"
                       "local X, Y = ns.Util, ns.Other or {}\n"
                       "U.Now()\n"
                       "local t = Now()\n"
                       "X:Key()\n"
                       "Y:Go()\n"
                       "-- U.Bad() in a comment\n"
                       'local s = "U.Fake() in a string"\n'
                       "local lim = ns.Util.LIMIT\n"
                       "print(lim)\n"),
    })
    try:
        dm = fk.build()
        e = edge(dm, "Core/A.lua", "Core/Util.lua")
        assert e is not None, dict(dm.edges)
        assert set(e.syms) == {"Util.Now", "Util.Key", "Util.LIMIT"}, e.syms
        assert e.syms["Util.Now"] == 2 and e.n == 4, (e.syms, e.n)           # U.Now() + Now(); the alias lines are not uses
        assert e.symline["Util.Now"] == 6, e.symline
        o = edge(dm, "Core/A.lua", "Core/Other.lua")
        assert o is not None and set(o.syms) == {"Other.Go"}, o and o.syms   # local O = {}; ns.Other = O
        assert dm.info["Core/A.lua"].aliases == {"U": "Util", "X": "Util", "Y": "Other"}, dm.info["Core/A.lua"].aliases
        assert ("Util", "Key") in dm.colon
        assert "Bad" not in str(dict(dm.refs)) and "Fake" not in str(dict(dm.refs))
    finally:
        fk.close()


def test_method_owners_split_across_files_and_hooks():
    fk = Fake({
        "Core/Perf.lua": ("local function wrap()\n  local Comm = ns.Comm\n"
                          "  Comm.Send = function(self, ...) end\nend\n"),               # a hook, loaded first
        "Core/Comm.lua": 'local Comm = ns:NewModule("Comm")\nfunction Comm:Send() end\n',
        "UI/Widgets.lua": 'local UI = ns:NewModule("UI")\nfunction UI:CreateButton() end\n',
        "UI/Comp/Controls.lua": "local UI = ns.UI\nfunction UI:CreatePill() end\nUI.PILL = {}\n",
        "UI/Page.lua": "local UI = ns.UI\nUI:CreatePill()\nUI:CreateButton()\nlocal p = UI.PILL\nns.Comm:Send()\n",
    })
    try:
        dm = fk.build()
        assert dm.owner_meth[("UI", "CreatePill")] == "UI/Comp/Controls.lua"
        assert dm.owner_meth[("UI", "PILL")] == "UI/Comp/Controls.lua"
        assert dm.owner_meth[("Comm", "Send")] == "Core/Comm.lua", dm.owner_meth   # the hook does not steal it
        assert set(edge(dm, "UI/Page.lua", "UI/Comp/Controls.lua").syms) == {"UI.CreatePill", "UI.PILL"}
        assert set(edge(dm, "UI/Page.lua", "UI/Widgets.lua").syms) == {"UI.CreateButton"}
        assert set(edge(dm, "UI/Page.lua", "Core/Comm.lua").syms) == {"Comm.Send"}
        assert "UI/Comp/Controls.lua" in [f for f in dm.files] and dm.external_api("UI/Comp/Controls.lua")["UI.CreatePill"] == 1
    finally:
        fk.close()


def test_upward_edges_and_kit():
    fk = Fake({
        "Core/Init.lua": 'function ns:Fire(msg) end\nfunction ns:On(msg, fn) end\n',
        "Core/Util.lua": 'local Util = ns:NewModule("Util")\nfunction Util.Open() return ns.MainFrame:Toggle() end\n',
        "UI/Style.lua": "local S = {}\nns.Style = S\nfunction S.Pad() return ns.RaidsTab:Count() end\n",
        "UI/MainFrame.lua": 'local MF = ns:NewModule("MainFrame")\nfunction MF:Toggle() ns:Fire("X") end\n'
                            'local u = ns.Util.Open\n',
        "UI/RaidsTab.lua": 'local R = ns:NewModule("RaidsTab")\nfunction R:Count() return ns.Style.Pad() end\n',
    })
    try:
        dm = fk.build()
        k = kinds(dm)
        assert ("up", "Core/Util.lua", "UI/MainFrame.lua") in k, k
        assert ("kit", "UI/Style.lua", "UI/RaidsTab.lua") in k, k
        assert not any(v[1] == "UI/MainFrame.lua" for v in k), k            # UI -> Core / Init is downward
        assert not any(v[1] == "UI/RaidsTab.lua" for v in k), k             # a page may use the kit
        assert set(edge(dm, "UI/MainFrame.lua", "Core/Init.lua").syms) == {"ns.Fire"}
        assert dm.display("ns.Fire") == "ns:Fire"
        v = [x for x in L.violations(dm) if x.kind == "up"][0]
        assert v.ls == 0 and v.ld == 5 and v.syms == {"MainFrame.Toggle"}, (v.ls, v.ld, v.syms)
    finally:
        fk.close()


def test_feature_order():
    fk = Fake({
        "Core/Guild.lua": 'local G = ns:NewModule("Guild")\nfunction G:IsOfficer() return ns.RaidPlan:Get() end\n',
        "Core/RaidPlan.lua": ('local RP = ns:NewModule("RaidPlan")\nfunction RP:Get() return ns.Guild:IsOfficer() end\n'
                              'function RP:Stats() return ns.Loot:Count() end\n'),
        "Core/Loot.lua": 'local Lo = ns:NewModule("Loot")\nfunction Lo:Count() return ns.RaidPlan:Get() end\n',
        "Core/Events.lua": 'local E = ns:NewModule("Events")\nfunction E:A() return ns.Strategy:B(), ns.Loot:Count() end\n',
        "Core/Strategy.lua": 'local S = ns:NewModule("Strategy")\nfunction S:B() end\n',
        "Core/Comm.lua": 'local C = ns:NewModule("Comm")\nfunction C:Send() end\nfunction C:Register() end\n',
        "UI/RaidsTab.lua": 'local R = ns:NewModule("RaidsTab")\nfunction R:X() ns.Comm:Send() end\n',
    })
    try:
        dm = fk.build()
        k = kinds(dm)
        assert ("order", "Core/RaidPlan.lua", "Core/Loot.lua") in k, k       # Raids may not call the later Loot
        assert ("order", "Core/Events.lua", "Core/Strategy.lua") in k, k     # siblings of one rank
        assert ("up", "Core/Guild.lua", "Core/RaidPlan.lua") in k, k         # L2 context -> L3 is upward
        assert not any(v[1] == "Core/Loot.lua" for v in k), k                # Loot -> Raids is the allowed way
        assert ("order", "Core/Events.lua", "Core/Loot.lua") not in k, k
        assert not any(v[1] == "UI/RaidsTab.lua" for v in k), k              # UI -> Sync is downward
        out = io.StringIO()
        L.report(dm, out=out)
        text = out.getvalue()
        assert "Raids <-> Loot" in text or "Loot <-> Raids" in text, text
        assert "L2 Context -> L3 Feature logic: 1 pairs" in text, text
    finally:
        fk.close()


def test_allowlist_baseline_new_stale_prune():
    files = {
        "Core/Util.lua": 'local Util = ns:NewModule("Util")\nfunction Util.A() return ns.MainFrame:Open() end\n',
        "UI/MainFrame.lua": 'local MF = ns:NewModule("MainFrame")\nfunction MF:Open() end\nfunction MF:Close() end\n',
    }
    fk = Fake(files)
    try:
        allow_path = fk.path("allow.json")
        dm = fk.build()
        data = L.baseline(L.violations(dm), fk.cfg, allow_path)
        assert data["counts"] == {"up": 1}, data
        new, stale = L.compare(L.violations(dm), L.load_allow(allow_path))
        assert new == [] and stale == []
        # a new symbol on the allowed pair and a new pair
        fk.files["Core/Util.lua"] += "function Util.B() ns.MainFrame:Close() end\n"
        fk.files["Core/DB.lua"] = "local x = ns.MainFrame:Open()\n"
        fk.write()
        dm = fk.build()
        new, stale = L.compare(L.violations(dm), L.load_allow(allow_path))
        got = {(v.src, frozenset(s)) for v, s in new}
        assert got == {("Core/Util.lua", frozenset({"MainFrame.Close"})),
                       ("Core/DB.lua", frozenset({"MainFrame.Open"}))}, got
        rows, _, _, _ = L.lint(dm, L.load_allow(allow_path), strict=True)
        assert all(r[2] == "ERROR" for r in rows if r[3] == "layers") and len(rows) == 2, rows
        assert any("new symbols on an allowed pair" in r[5] for r in rows), rows
        rows, _, _, _ = L.lint(dm, L.load_allow(allow_path), only={"Core/DB.lua"})
        assert [r[0] for r in rows] == ["Core/DB.lua"] and rows[0][2] == "WARN", rows
        # the old call goes away: the entry is stale, prune drops it and never adds the new ones
        fk.files = {"Core/Util.lua": 'local Util = ns:NewModule("Util")\nfunction Util.A() end\n',
                    "UI/MainFrame.lua": files["UI/MainFrame.lua"], "Core/DB.lua": "local x = ns.MainFrame:Open()\n"}
        fk.write()
        dm = fk.build()
        new, stale = L.compare(L.violations(dm), L.load_allow(allow_path))
        assert [(k, w) for k, _, w in stale] == [(("up", "Core/Util.lua", "UI/MainFrame.lua"), True)], stale
        data, rp, rs = L.prune(L.violations(dm), L.load_allow(allow_path), allow_path)
        assert rp == 1 and data["entries"] == [], data
        # symbol-level shrink
        L.baseline(L.violations(dm), fk.cfg, allow_path)
        a = L.load_allow(allow_path)
        a["entries"][0]["syms"].append("MainFrame.Gone")
        with open(allow_path, "w", encoding="utf-8") as fh:
            json.dump(a, fh)
        new, stale = L.compare(L.violations(dm), L.load_allow(allow_path))
        assert stale == [(("up", "Core/DB.lua", "UI/MainFrame.lua"), {"MainFrame.Gone"}, False)], stale
        data, rp, rs = L.prune(L.violations(dm), L.load_allow(allow_path), allow_path)
        assert (rp, rs) == (0, 1) and data["entries"][0]["syms"] == ["MainFrame.Open"], data
        # rename after a move
        data = L.rename({"Core/DB.lua": "Core/Database.lua"}, L.load_allow(allow_path), allow_path)
        assert data["entries"][0]["from"] == "Core/Database.lua"
        with open(fk.path("moves.json"), "w") as fh:
            json.dump([["Core/Database.lua", "Core/DB.lua"]], fh)
        assert L.load_moves(fk.path("moves.json")) == {"Core/Database.lua": "Core/DB.lua"}
    finally:
        fk.close()


def test_check_py_layers_flags():
    import check  # needs lupa (luaenv python)
    fk = Fake({
        "Core/Util.lua": 'local Util = ns:NewModule("Util")\nfunction Util.A() return ns.MainFrame:Open() end\n',
        "UI/MainFrame.lua": 'local MF = ns:NewModule("MainFrame")\nfunction MF:Open() end\n',
    })
    saved = (check.ADDON_DIR, check.LAYERS_CONFIG, check.LAYERS_ALLOW)
    try:
        cfg_path, allow_path = fk.path("layers.json"), fk.path("allow.json")
        with open(cfg_path, "w", encoding="utf-8") as fh:
            json.dump(CFG, fh)
        check.ADDON_DIR, check.LAYERS_CONFIG, check.LAYERS_ALLOW = fk.root, cfg_path, allow_path

        def run(*a):
            out = io.StringIO()
            with redirect_stdout(out):
                rc = check.main(list(a))
            return rc, out.getvalue()

        rc, text = run("--layers")
        assert rc == 0 and "WARN LAYERS up Core/Util.lua -> UI/MainFrame.lua" in text and "1 new" in text, text
        rc, text = run("--layers", "--strict")
        assert rc == 1 and "ERROR LAYERS up" in text, text
        L.baseline(L.violations(fk.build()), fk.cfg, allow_path)
        rc, text = run("--layers", "--strict")
        assert rc == 0 and "0 new, 0 stale" in text, text
        rc, text = run("--no-events", "--no-uniformity")             # a normal run includes the lint
        assert rc == 0 and "LAYERS" not in text, text
        fk.files["Core/Util.lua"] = 'local Util = ns:NewModule("Util")\n'
        fk.write()
        rc, text = run("--no-events", "--no-uniformity")
        assert rc == 0 and "WARN LAYERS-STALE allowlist entry up Core/Util.lua -> UI/MainFrame.lua" in text, text
        rc, text = run("--no-events", "--no-uniformity", os.path.join(fk.root, "Core", "Util.lua"))
        assert "LAYERS-STALE" not in text, text                       # stale entries: whole-addon runs only
        rc, text = run("--prune")
        assert rc == 0 and L.load_allow(allow_path)["entries"] == [], text
        rc, text = run("--layers", "--headers")
        assert "WARN HEADER missing" in text and "2 header warning(s)" in text, text
    finally:
        check.ADDON_DIR, check.LAYERS_CONFIG, check.LAYERS_ALLOW = saved
        fk.close()


HEADER = """-- Module   RaidPlan (read API)                      Layer  3 · Logic/Raids
-- Owns     db.raidPlan[guild] (raids, teams, series);
--          never written outside Logic/Raids/RaidPlan
-- Uses     Context.Guild, Items.ItemDB,
--          Gear.BiS (spec only via Context.Me)
-- Fires    RAIDPLAN_CHANGED(id), RAIDPLAN_SIGNUP(id, key)
-- API
--   RaidPlan:GetRaid(id)            -> raid | nil           a copy is never returned;
--                                                          read-only
--   RaidPlan:IsPast(raid, now)      -> bool                 PAST_GRACE = 6 h
-- The rest of this comment is prose, not header.
local addonName, ns = ...
"""


def test_header_parsing():
    h = M.parse_header(GUARD % ("Core/RaidPlan.lua", "x") + HEADER)
    assert h and h.module == "RaidPlan" and h.part == "read API" and h.layer == 3 and h.folder == "Logic/Raids", h
    assert h.line == 2
    assert "never written outside" in h.owns, h.owns
    assert h.uses == ["Guild", "ItemDB", "BiS"], h.uses
    assert h.fires.startswith("RAIDPLAN_CHANGED"), h.fires
    assert [a[0] for a in h.api] == ["RaidPlan:GetRaid", "RaidPlan:IsPast"], h.api
    assert h.api[0][1] == "(id)" and "read-only" in h.api[0][2] and h.api[0][3] == 9, h.api[0]
    # prose that starts with "Module" is not a header; no guard = parse from line 1
    assert M.parse_header(GUARD % ("Core/Init.lua", "x") + "-- Module registry + lifecycle (OnInit)\nlocal a\n") is None
    assert M.parse_header("-- Module Boot  Layer 0 · Core\nlocal a\n").module == "Boot"
    assert M.parse_uses("Util, none") == ["Util"] and M.parse_uses("") == []


def test_header_checks_and_doc():
    fk = Fake({
        "Core/Guild.lua": 'local G = ns:NewModule("Guild")\nfunction G:IsOfficer() end\n',
        "Core/ItemDB.lua": 'local I = ns:NewModule("ItemDB")\nfunction I:Get() end\n',
        "Core/RaidPlan.lua": HEADER.replace("Context.Guild, ", "") + (
            'local RP = ns:NewModule("RaidPlan")\nfunction RP:GetRaid(id) return ns.Guild:IsOfficer(), '
            'ns.ItemDB:Get() end\n'),
        "Core/Loot.lua": HEADER.replace("RaidPlan (read API)", "Loot").replace("Layer  3", "Layer  2") + (
            'local Lo = ns:NewModule("Loot")\nfunction Lo:X() return ns.Guild:IsOfficer(), ns.ItemDB:Get() end\n'),
    })
    try:
        dm = fk.build()
        rows = M.check(dm)
        got = {(f, cat, nm) for f, _, cat, nm, _ in rows}
        assert ("Core/Guild.lua", "missing", "") in got and ("Core/ItemDB.lua", "missing", "") in got, got
        assert ("Core/RaidPlan.lua", "uses", "Guild") in got, got                 # calls Guild, Uses omits it
        assert ("Core/RaidPlan.lua", "api", "RaidPlan:IsPast") in got, got        # not defined anywhere
        assert ("Core/RaidPlan.lua", "api", "RaidPlan:GetRaid") not in got, got
        assert ("Core/Loot.lua", "layer", "2") in got, got                        # layers.json says 3
        assert not any(f == "Core/Loot.lua" and cat == "uses" for f, cat, _ in got), got
        line = [ln for f, ln, cat, _, _ in rows if f == "Core/RaidPlan.lua" and cat == "api"][0]
        assert line == 11, line                                                   # guard + header line 10
        doc = M.render(dm)
        assert "## Layer 3 · Feature logic" in doc and "### RaidPlan (read API)" in doc, doc
        assert "| `RaidPlan:GetRaid` | `(id)` |" in doc, doc
        assert "### No header yet" in doc and "`Guild:IsOfficer`×2" in doc, doc
    finally:
        fk.close()


def test_lua_limits():
    import check
    import luabc
    src = "\n".join("local a%d = %d" % (i, i) for i in range(175)) + "\n"
    rows = luabc.limits(luabc.parse_bytecode(luabc.compile_chunk(src, "@x")[0]))
    assert rows[0]["main"] and rows[0]["locals"] == 175 and rows[0]["locals_line"] == 175, rows[0]
    up = "\n".join("local u%d = %d" % (i, i) for i in range(50))
    src = up + "\nlocal function Fill(b)\n  return " + " + ".join("u%d" % i for i in range(50)) + "\nend\n"
    rows = luabc.limits(luabc.parse_bytecode(luabc.compile_chunk(src, "@x")[0]))
    assert rows[1]["upvalues"] == 50 and rows[1]["line"] == 51, rows[1]
    # nested blocks: a closed block's locals are not active any more
    src = "do local a, b, c = 1, 2, 3 end\nlocal d = 4\nlocal function f(x) local y = x end\nreturn f\n"
    rows = luabc.limits(luabc.parse_bytecode(luabc.compile_chunk(src, "@x")[0]))
    assert rows[0]["locals"] == 3 and rows[1]["locals"] == 2, rows
    d = tempfile.mkdtemp(prefix="dz_limits_")
    try:
        f = os.path.join(d, "Big.lua")
        with open(f, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join("local a%d = %d" % (i, i) for i in range(200)) + "\n")
        g = os.path.join(d, "Ups.lua")
        with open(g, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(up + "\nlocal function Fill(b)\n  return " + " + ".join("u%d" % i for i in range(50)) + "\nend\n")
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([f, g, "--no-events", "--no-uniformity", "--no-layers"])
        text = out.getvalue()
        assert rc == 1 and "ERROR LIMIT locals: main chunk has 200 active locals" in text, text
        assert "Ups.lua:51: WARN LIMIT upvalues: Fill (lines 51-53) uses 50 upvalues" in text, text
        assert "limits=2" in text and "1 layer/limit error(s)" in text, text
        out = io.StringIO()
        with redirect_stdout(out):
            rc = check.main([g, "--no-events", "--no-uniformity", "--no-limits"])
        assert rc == 0 and "LIMIT" not in out.getvalue(), out.getvalue()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_real_config_today_and_after_the_move():
    cfg = L.load_config()
    want = {
        # today's paths
        "Core/Util.lua": (0, "Platform"), "Core/Boot.lua": (0, "Platform"), "Core/Comm.lua": (4, "Sync"),
        "Core/DigestSync.lua": (4, "Sync"), "Core/Guild.lua": (2, "Context"), "Core/GroupRules.lua": (2, "Context"),
        "Core/ItemDB.lua": (2, "Items"), "Core/RaidPlan.lua": (3, "Raids"), "Core/Roll.lua": (3, "Loot"),
        "Core/Professions.lua": (3, "Guild"), "Core/BiS.lua": (3, "Gear"), "Core/Meter.lua": (3, "Combat"),
        "Core/Totems.lua": (3, "ClassTools"), "Core/Polls.lua": (3, "Events"), "Data/Items.lua": (1, "Items"),
        "Data/BossJournal.lua": (1, "Strategy"), "Data/Tours/Welcome.lua": (5, "Tours"), "Sim/Core.lua": (3, "Gear"),
        "Render3D/View.lua": (5, "Render3D"), "Render3D/Probe.lua": (5, "Dev"), "UI/Widgets.lua": (5, "Kit"),
        "UI/Comp/Controls.lua": (5, "Kit"), "UI/MainFrame.lua": (5, "Shell"), "UI/RaidPlanUI.lua": (5, "Raids"),
        "UI/EventBuilder.lua": (5, "Events"), "DisasterZone_Chess/AI.lua": (6, "Games"),
        # the target folders (P4 only edits layers.json)
        "Core/Time.lua": (0, "Platform"), "Logic/Context/Roster.lua": (2, "Context"),
        "Logic/Items/ItemDB.lua": (2, "Items"), "Logic/Gear/BiS.lua": (3, "Gear"),
        "Logic/Raids/RaidPlan/Read.lua": (3, "Raids"), "Logic/ClassTools/Totems.lua": (3, "ClassTools"),
        "Sync/BiSListNet.lua": (4, "Sync"), "UI/Kit/Widgets/Buttons.lua": (5, "Kit"),
        "UI/Shell/MainFrame.lua": (5, "Shell"), "UI/Tours/Welcome.lua": (5, "Tours"),
        "UI/Events/Builder/Kit.lua": (5, "Events"), "UI/Dev/Probe.lua": (5, "Dev"),
        "UI/Raids/Teams/Board.lua": (5, "Raids"), "DisasterZone_Bingo/UI.lua": (6, "Games"),
    }
    got = {p: (cfg.layer(p), cfg.feature(p)) for p in want}
    bad = {p: (got[p], w) for p, w in want.items() if got[p] != w}
    assert not bad, bad
    names = {f for grp in cfg.order for f in grp}
    assert names == {"Context", "Items", "Gear", "Guild", "Raids", "Loot", "Events", "Strategy", "Combat",
                     "ClassTools"}, names


def test_real_addon_fully_mapped():
    root = L.default_addon_dir()
    if not os.path.isdir(root):
        print("  (skipped: no addon at %s)" % root)
        return
    dm = L.build(root)
    unmapped = [f for f in dm.files if dm.info[f].layer is None or dm.info[f].feature == "?"]
    assert not unmapped, unmapped
    assert not [p for p in dm.config.files if p not in dm.info], "layers.json overrides name missing files"


def main():
    only = None
    if "-k" in sys.argv:
        only = sys.argv[sys.argv.index("-k") + 1]
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        if only and only not in name:
            continue
        try:
            fn()
            print("PASS %s" % name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            import traceback
            traceback.print_exc()
            print("FAIL %s: %s: %s" % (name, type(e).__name__, e))
    print("-- %s" % ("all passed" if not failed else "%d failed" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
