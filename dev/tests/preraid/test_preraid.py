#!/usr/bin/env python
"""The Pre-raid phase (phase 0) of My BiS lists, on the real addon.

The Pre-raid picks are stored flat next to the raid phases (data.pr = { [sid] = { main, alt } }, data.px = { [sid] =
true }, off spec data.opr / data.opx; omitted when empty) because released validators only accept ph / dx phases 1..5
but let unknown top-level keys through and verify the hash over every key. Covers: a phase-0 round trip in both specs
(edits, disabled slots, copies between Pre-raid and P1, templates, sanitizing); a Pre-raid-only list commits, reaches
the council and is restored after a reinstall, and is never replaced silently by an older council copy; a DisasterZone
1.3.0 council client (unpacked from dist/DisasterZone-1.3.0.zip) stores, relays and restores it untouched and never
lists it as a wanter; the council's view, drop matching and loot alerts stay on the raid phases while my own tooltip
shows the Pre-raid pick; the obtained list (ob) stays on the raid phases; the fullest list fits the member wire cap;
malformed Pre-raid fields are rejected.

Run: luaenv\\Scripts\\python.exe tests\\preraid\\test_preraid.py   [-k substring]
"""
import os
import random
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
SCRATCH = os.path.dirname(TESTS)
REPO = os.path.dirname(SCRATCH)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import (Runner, Client, new_world, up, settle, key, own, cached, candidates, wipe_saved,  # noqa: E402
                    restore_saved, printed, logical_messages)

r = Runner("pre-raid lists")
RK, C1K, C2K = key("Raider"), key("Councila"), key("Councilb")

DIST_130 = os.path.join(REPO, "dist", "DisasterZone-1.3.0.zip")
UNPACKED_130 = os.path.join(SCRATCH, "tf_e", "_addon130")       # git-ignored (tf_e/*/), unpacked once
MAX_WIRE_LEN_MEMBER = 4000          # Core/Comm.lua: what a council client accepts from a member
MAX_INFLATED_LEN_MEMBER = 16384
MAX_WIRE_LEN = 24000                # from council (relays: 8 lists per R)


def addon_130():
    """The released 1.3.0 addon folder (unpacked from dist/ on first use), or None when the zip is missing."""
    folder = os.path.join(UNPACKED_130, "DisasterZone")
    if os.path.exists(os.path.join(folder, "DisasterZone.toc")):
        return folder
    if not os.path.exists(DIST_130):
        return None
    tmp = "%s.%d.tmp" % (UNPACKED_130, os.getpid())
    with zipfile.ZipFile(DIST_130) as z:
        z.extractall(tmp)
    try:
        os.rename(tmp, UNPACKED_130)
    except OSError:                  # unpacked meanwhile by another run: use that one (the temp copy stays behind)
        pass
    return folder


def norm(t):
    """A Lua table that came back as a list (keys 1..n) or a dict: {int key: value}."""
    if t is None:
        return None
    if isinstance(t, list):
        return {i + 1: v for i, v in enumerate(t) if v is not None}
    return {int(k): v for k, v in t.items() if v is not None}


def data_of(c, owner=None):
    if owner is None:
        return c.eval_py("return ns.BiS:GetData()")
    return c.eval_py("local r = ns.Store:GetCached(...) return r and r.data", owner)


def bis(c, call, *args):
    return c.eval("return ns.BiS:" + call, *args)


def solo(name="Raider", cls="PALADIN"):
    w = new_world()
    c = Client(w, name, class_file=cls, guild_rank=3)
    up(c)
    settle(w, 5)
    return w, c


def trio(c1_online=True, c2_online=False, c1_dir=None):
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1, online=c1_online, addon_dir=c1_dir)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=c2_online)
    for c in (R, C1, C2):
        if c.online:
            up(c)
    return w, R, C1, C2


def wanters(c, item):
    return c.eval_py("""
      local out = {}
      for _, w in ipairs(ns.Store:GetWanters(..., { includeObtained = true, list = 'both' })) do
        out[#out + 1] = w.key .. ':' .. tostring(w.phase)
      end
      return out""", item) or []


# ------------------------------------------------------------------------------------------------------------------
@r.case
def phase_zero_round_trip_in_both_specs():
    w, R = solo()
    head1, head2 = candidates(R, 1, 2)
    chest = candidates(R, 5, 1)[0]
    live0 = R.eval("return ns.Util.Hash(ns.BiS:GetData())")
    assert bis(R, "SetSlot(0, 1, 'main', ...)", head1) is True
    assert bis(R, "SetSlot(0, 1, 'alt', ...)", head2) is True
    assert bis(R, "SetSlot(0, 5, 'main', ...)", chest) is True
    assert R.eval("return ns.BiS:GetSlot(0, 1)") == (head1, head2)
    assert R.eval("return ns.BiS:GetSlot(1, 1)") is None
    d = data_of(R)
    assert norm(d["pr"]) == {1: [head1, head2], 5: [chest, 0]}, d.get("pr")
    assert not d.get("ph"), "a Pre-raid pick went into ph: %s" % d.get("ph")
    assert "px" not in d and "opr" not in d and "opx" not in d, d
    assert R.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    rows = R.eval_py("local o = {} for _, x in ipairs(ns.BiS:GetPhaseItems(0)) do o[#o + 1] = { x.sid, x.which, x.itemID } end "
                     "return o")
    assert rows == [[1, "main", head1], [1, "alt", head2], [5, "main", chest]], rows
    assert R.eval("return ns.ListPhase(ns.BiS:GetData(), 0)[5][1]") == chest
    assert bis(R, "SwapMainAlt(0, 1)") is True
    assert R.eval("return ns.BiS:GetSlot(0, 1)") == (head2, head1)
    assert bis(R, "ClearSlot(0, 5)") is True
    assert norm(data_of(R)["pr"]) == {1: [head2, head1]}
    # phases outside 0..5 are refused
    for p in (-1, 6, 0.5):
        assert bis(R, "SetSlot(..., 1, 'main', select(2, ...))", p, head1) is False, p
    # the off spec has its own Pre-raid list (opr), the main one is untouched
    assert bis(R, "AddOffSpec('Protection')") is True
    assert bis(R, "SetSlot(0, 1, 'main', ..., 'os')", head1) is True
    d = data_of(R)
    assert norm(d["opr"]) == {1: [head1, 0]} and norm(d["pr"]) == {1: [head2, head1]}, d
    assert R.eval("return (ns.BiS:GetSlot(0, 1, 'os'))") == head1
    assert R.eval("return ns.ListView(ns.BiS:GetData(), 'os').pr[1][1]") == head1
    assert R.eval("return ns.ListPhase(ns.BiS:GetData(), 0, 'os')[1][1]") == head1
    assert R.eval("return ns.ListPhase(ns.ListView(ns.BiS:GetData(), 'os'), 0)[1][1]") == head1
    assert R.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    # clearing the phase drops the field (same hash as a list that never had one)
    assert bis(R, "ClearPhase(0, 'os')") is True
    d = data_of(R)
    assert "opr" not in d and d["os"] == "Protection", d
    assert bis(R, "SetSlot(0, 2, 'main', ..., 'os')", candidates(R, 2, 1)[0]) is True
    assert bis(R, "RemoveOffSpec()") is True
    d = data_of(R)
    assert "opr" not in d and "os" not in d and "opx" not in d, d
    assert bis(R, "ClearPhase(0)") is True
    assert "pr" not in data_of(R)
    assert R.eval("return ns.Util.Hash(ns.BiS:GetData())") == live0, "an emptied Pre-raid list changed the hash"
    # labels
    assert R.eval_py("return { ns.PhaseLabel(0), ns.PhaseLabel(3), ns.PHASE_INFO[0].short, #ns.PHASES, #ns.LIST_PHASES }") \
        == ["Pre-raid", "P3", "Pre-raid", 5, 6]
    w.assert_no_errors()


@r.case
def pre_raid_disabled_slots_and_every_phase_switch():
    w, R = solo()
    neck = candidates(R, 2, 1)[0]
    assert bis(R, "SetSlot(0, 2, 'main', ...)", neck) is True
    assert bis(R, "SetSlotDisabled(0, 2, true)") is True
    d = data_of(R)
    assert norm(d["px"]) == {2: True} and "dx" not in d, d
    assert bis(R, "IsSlotDisabled(0, 2)") is True and bis(R, "IsSlotDisabled(1, 2)") is False
    assert norm(R.eval_py("return ns.BiS:GetDisabledSlots(0)")) == {2: True}
    assert R.eval("return ns.Store:IsSlotDisabled(ns.BiS:GetData(), 0, 2)") is True
    assert R.eval("return ns.Store:IsSlotDisabled(ns.BiS:GetData(), 1, 2)") is False
    assert R.eval("return ns.ListDisabled(ns.BiS:GetData(), 0)[2]") is True
    assert R.eval_py("local x = ns.BiS:GetPhaseItems(0)[1] return { x.itemID, x.disabled }") == [neck, True]
    # a template / copy never fills a disabled slot
    assert bis(R, "ApplyTemplate(0, { [2] = { ... } }, true)", candidates(R, 2, 2)[1]) == 0
    assert R.eval("return (ns.BiS:GetSlot(0, 2))") == neck
    # every phase: Pre-raid and P1..P5
    assert bis(R, "SetSlotDisabledAllPhases(4, true)") is True
    d = data_of(R)
    assert norm(d["px"]) == {2: True, 4: True}, d["px"]
    assert sorted(norm(d["dx"])) == [1, 2, 3, 4, 5] and all(norm(v) == {4: True} for v in norm(d["dx"]).values()), d
    assert bis(R, "SetSlotDisabledAllPhases(4, false)") is True
    d = data_of(R)
    assert norm(d["px"]) == {2: True} and "dx" not in d, d
    assert bis(R, "SetSlotDisabled(0, 2, false)") is True
    assert "px" not in data_of(R)
    # the off spec: opx
    assert bis(R, "SetSlotDisabled(0, 7, true, 'os')") is True
    d = data_of(R)
    assert norm(d["opx"]) == {7: True} and d.get("os") == "" and "px" not in d, d
    assert R.eval("return ns.Store:IsSlotDisabled(ns.BiS:GetData(), 0, 7, 'os')") is True
    assert R.eval("return ns.BiS:HasOffSpec()") is True and R.eval("return ns.HasOffSpec(ns.BiS:GetData())") is True
    assert bis(R, "RemoveOffSpec()") is True and "opx" not in data_of(R)
    w.assert_no_errors()


@r.case
def copies_between_pre_raid_and_p1_and_the_bundled_template():
    w, R = solo()
    h1, h2, h3 = candidates(R, 1, 3)
    c1, c2 = candidates(R, 5, 2)
    g1 = candidates(R, 7, 1)[0]
    for phase, sid, which, item in ((0, 1, "main", h1), (0, 1, "alt", h2), (0, 5, "main", c1), (1, 5, "main", c2),
                                    (1, 7, "main", g1)):
        assert bis(R, "SetSlot(...)", phase, sid, which, item) is True
    assert bis(R, "SetSlotDisabled(1, 7, true)") is True
    # fill empty: P1 gets the head (main + alt), keeps its own chest
    assert bis(R, "CopyPhase(0, 1, false)") is True
    p1 = norm(data_of(R)["ph"])[1]
    assert norm(p1) == {1: [h1, h2], 5: [c2, 0], 7: [g1, 0]}, p1
    # overwrite: P1 becomes the Pre-raid list, its disabled slot keeps its pick
    assert bis(R, "CopyPhase(0, 1, true)") is True
    assert norm(norm(data_of(R)["ph"])[1]) == {1: [h1, h2], 5: [c1, 0], 7: [g1, 0]}
    # and back: P1 -> Pre-raid
    assert bis(R, "SetSlot(1, 1, 'main', ...)", h3) is True
    assert bis(R, "CopyPhase(1, 0, true)") is True
    assert norm(data_of(R)["pr"]) == {1: [h3, h2], 5: [c1, 0], 7: [g1, 0]}, data_of(R)["pr"]
    # same phase of the same list: refused; the other spec's Pre-raid: fine
    assert bis(R, "CopyPhase(0, 0, false)") is False
    assert bis(R, "CopyPhase(0, 0, false, 'os', 'ms')") is True
    assert norm(data_of(R)["opr"]) == norm(data_of(R)["pr"])
    # every guide's Pre-raid list builds a template that fills the phase
    tpl = R.eval_py("return ns.Loon:GetTemplate('PALADIN', 'Holy', 0)")
    assert tpl and len(norm(tpl)) >= 10, tpl
    n = bis(R, "ApplyTemplate(0, ns.Loon:GetTemplate('PALADIN', 'Holy', 0), true)")
    assert n and n > 0, n
    assert R.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    w.assert_no_errors()


@r.case
def every_spec_gets_a_pre_raid_template():
    # Data/BiSLists.lua as generated: every spec of every class has a Pre-raid list (the guides' phase 0)
    w, R = solo()
    res = R.eval_py("""
      local bad, n = {}, 0
      for class, specs in pairs(ns.SPECS) do
        for _, spec in ipairs(specs) do
          local tpl = ns.Loon:GetTemplate(class, spec.label, 0)
          if not tpl then
            bad[#bad + 1] = class .. ' ' .. spec.label .. ': no Pre-raid template'
          else
            local slots = 0
            for sid, pair in pairs(tpl) do
              slots = slots + 1
              if not ns.ItemDB:FitsSlot(pair[1], sid) then bad[#bad + 1] = class .. ' ' .. spec.label .. ' sid ' .. sid end
            end
            if slots < 12 then bad[#bad + 1] = class .. ' ' .. spec.label .. ': ' .. slots .. ' slots' end
            n = n + 1
          end
        end
      end
      return { bad = bad, n = n, neg = ns.Loon:GetTemplate('PALADIN', 'Holy', -1) == nil }""")
    assert list(res["bad"] or []) == [], list(res["bad"])[:20]
    assert res["n"] >= 27 and res["neg"] is True, res
    w.assert_no_errors()


@r.case
def saved_pre_raid_fields_are_repaired_on_load():
    w, R = solo()
    head = candidates(R, 1, 1)[0]
    R.eval("""
      local d = ns.BiS:GetData()
      d.pr = { [0] = { 1, 2 }, [1] = { ..., ... }, [3] = 'x', [18] = { 1, 0 }, [5] = { 0, 0 } }
      d.px = { [2] = true, [3] = 1, [40] = true }
      d.opr = 'junk'
      d.opx = {}""", head, head)
    R.relog()
    settle(w, 4)
    d = data_of(R)
    assert norm(d["pr"]) == {1: [head, 0]}, d.get("pr")
    assert norm(d["px"]) == {2: True}, d.get("px")
    assert "opr" not in d and "opx" not in d and "os" not in d, d
    assert R.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    w.assert_no_errors()


@r.case
def malformed_pre_raid_fields_are_rejected():
    w, R = solo()
    head = candidates(R, 1, 1)[0]
    bad = {
        "pr = 'x'": "pre-raid: bad picks",
        "pr = { [0] = { %d, 0 } }": "pre-raid: bad slot",
        "pr = { [18] = { %d, 0 } }": "pre-raid: bad slot",
        "pr = { [1] = { %d, 0, 5 } }": "pre-raid: bad slot item",
        "pr = { [1] = { 'x' } }": "pre-raid: bad slot item",
        "pr = { [1] = { 300000 } }": "pre-raid: bad slot item",
        "pr = { [1] = { { %d } } }": None,       # too deep for the shape check or a bad item: rejected either way
        "px = { [1] = 1 }": "pre-raid: bad disabled slot",
        "px = { [0] = true }": "pre-raid: bad disabled slot",
        "px = 5": "pre-raid: bad disabled slots",
        "opr = { [1] = 7 }": "off spec pre-raid: bad slot",
        "opx = { [2] = false }": "off spec pre-raid: bad disabled slot",
    }
    for change, err in bad.items():
        code = change % head if "%d" in change else change
        res = R.eval_py("local d = ns.Util.CopyTable(ns.BiS:GetData()); d." + code + "; return { ns.Store:ValidateData(d) }")
        assert res[0] is False, (change, res)
        if err:
            assert res[1] == err, (change, res)
    ok = R.eval("local d = ns.Util.CopyTable(ns.BiS:GetData()); d.pr = { [1] = { ..., 0 } }; d.px = { [17] = true }; "
                "d.opr = { [2] = { 0, ... } }; d.opx = { [1] = true }; return ns.Store:ValidateData(d)", head)
    assert ok is True
    # a council client rejects such a list even with a matching hash
    w2, R2, C1, _ = trio()
    settle(w2, 30)
    stored = C1.eval("""
      local d = { v = 1, cl = 'PALADIN', sp = '', ph = {}, ob = {}, eq = {}, pr = { [1] = { 1, 2, 3 } } }
      return ns.Store:Put(..., { r = 5, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }, 'direct')""", RK)
    assert stored is False and cached(C1, RK) is None
    w.assert_no_errors()
    w2.assert_no_errors()


@r.case
def pre_raid_only_list_commits_syncs_and_restores():
    w, R, C1, C2 = trio()
    settle(w, 30)
    head1, head2 = candidates(R, 1, 2)
    assert bis(R, "SetSlot(0, 1, 'main', ...)", head1) is True
    R.eval("ns.BiS:Commit()")
    settle(w, 5)
    o = own(R)
    assert o["rev"] == 1 and not o["dirty"], "a Pre-raid-only list did not commit: %s" % o
    c = cached(C1, RK)
    assert c and c["rev"] == 1 and c["hash"] == o["hash"] == c["live"], (c, o)
    assert norm(data_of(C1, RK)["pr"]) == {1: [head1, 0]}
    # the council never lists it
    assert wanters(C1, head1) == [], wanters(C1, head1)
    # reinstall: restored silently, Pre-raid picks included
    R.logout()
    wipe_saved(w, R)
    settle(w, 2)
    R.login()
    settle(w, 45)
    o2 = own(R)
    assert o2["rev"] == 1 and o2["hash"] == o["hash"], (o2, o)
    assert norm(data_of(R)["pr"]) == {1: [head1, 0]}
    assert any("Restored your BiS list" in p for p in printed(R))
    # an older local copy holding only Pre-raid picks is not replaced without asking
    old_sv = R.saved_variables()
    assert bis(R, "SetSlot(0, 1, 'main', ...)", head2) is True
    R.eval("ns.BiS:Commit()")
    settle(w, 5)
    assert cached(C1, RK)["rev"] == 2
    R.logout()
    restore_saved(w, R, old_sv)
    settle(w, 2)
    R.login()
    settle(w, 35)
    assert own(R)["rev"] == 1, own(R)
    assert R.popups() == ["DISASTERZONE_RESTORE"], "expected the restore popup, got %s" % R.popups()
    assert norm(data_of(R)["pr"]) == {1: [head1, 0]}
    w.assert_no_errors()


@r.case
def council_view_drop_matching_and_alerts_stay_on_raid_phases():
    w, R, C1, C2 = trio()
    settle(w, 30)
    head, other = candidates(R, 1, 2)
    ring = candidates(R, 11, 1)[0]
    assert bis(R, "SetSlot(0, 1, 'main', ...)", head) is True       # Pre-raid only
    assert bis(R, "SetSlot(0, 11, 'main', ...)", ring) is True      # Pre-raid and P2
    assert bis(R, "SetSlot(2, 11, 'main', ...)", ring) is True
    R.eval("ns.BiS:Commit()")
    settle(w, 5)
    assert cached(C1, RK)["rev"] >= 1
    # council: wanters / summaries / index never show phase 0
    assert wanters(C1, head) == []
    assert wanters(C1, ring) == [RK + ":2"], wanters(C1, ring)
    s = C1.eval_py("return ns.Store:GetPlayerSummary(..., 2)", RK)
    assert s["filled"] == 1, s
    assert C1.eval_py("return ns.Store:GetPlayerSummary(..., 1)", RK)["filled"] == 0
    # my drop matching: only with preRaid, after the raid phases
    assert R.eval_py("return ns.BiS:MatchItem(...)", head) in ([], {}, None)
    m = R.eval_py("local o = {} for _, x in ipairs(ns.BiS:MatchItem(..., { preRaid = true })) do "
                  "o[#o + 1] = { x.phase, x.sid, x.which } end return o", head)
    assert m == [[0, 1, "main"]], m
    m = R.eval_py("local o = {} for _, x in ipairs(ns.BiS:MatchItem(..., { preRaid = true })) do "
                  "o[#o + 1] = x.phase end return o", ring)
    assert m == [2, 0], m
    assert R.eval_py("local o = {} for _, x in ipairs(ns.BiS:MatchItem(...)) do o[#o + 1] = x.phase end return o", ring) \
        == [2]
    # my tooltip shows the Pre-raid pick
    lines = [l for l, _ in R.show_tooltip_item(head) if l and "Your" in l]
    assert any("Your BiS Pre-raid · Head" in l for l in lines), lines
    lines = [l for l, _ in R.show_tooltip_item(ring) if l and "Your" in l]
    assert any("Your BiS Pre-raid, P2 · Ring 1" in l for l in lines), lines
    assert not [l for l, _ in R.show_tooltip_item(other) if l and "Your" in l]
    w.assert_no_errors()


@r.case
def obtained_list_stays_on_the_raid_phases():
    w, R = solo()
    head = candidates(R, 1, 1)[0]
    chest = candidates(R, 5, 1)[0]
    assert bis(R, "SetSlot(0, 1, 'main', ...)", head) is True
    assert bis(R, "SetSlot(1, 5, 'main', ...)", chest) is True
    R.set_bags({(0, 1): head, (0, 2): chest})
    settle(w, 3)
    assert R.eval("return ns.BiS:IsObtained(...)", head) is True
    ob = data_of(R).get("ob") or []
    assert chest in ob and head not in ob, ob
    w.assert_no_errors()


def fill_lua():
    return r"""
      local ids, worst = ...
      local n = 0
      local function nid() n = n + 1 return ids[n] end
      local function slots() local t = {} for sid = 1, 17 do t[sid] = { nid(), nid() } end return t end
      local function all() local t = {} for sid = 1, 17 do t[sid] = true end return t end
      local d = ns.BiS:GetData()
      d.ph, d.op = {}, {}
      for p = 1, 5 do d.ph[p] = slots() d.op[p] = slots() end
      d.pr, d.opr = slots(), slots()
      d.dx, d.ox, d.px, d.opx = nil, nil, nil, nil
      if worst then
        d.dx, d.ox = {}, {}
        for p = 1, 5 do d.dx[p] = all() d.ox[p] = all() end
        d.px, d.opx = all(), all()
      end
      d.sp, d.os = 'Retribution', 'Protection'
      local rec = ns.BiS:GetRecord()
      for i = 1, 200 do rec.manual[ids[i]] = true end      -- 200 obtained raid-phase picks: ob is full
      ns.BiS:RebuildDerived()
      d.eq = {}
      for sid = 1, 17 do d.eq[sid] = ids[#ids - sid + 1] end
      return #d.ob
    """


SIZE_LUA = r"""
  local msg = ...
  local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
  local s = LS:Serialize(msg)
  return 1 + #LD:EncodeForWoWAddonChannel(LD:CompressDeflate(s)), #s
"""


def rand_ids(seed, n=408):
    rnd = random.Random(seed)
    return rnd.sample(range(100000, 200001), n)


@r.case
def fullest_list_fits_the_member_cap_and_relay_batches():
    w, R, C1, C2 = trio()
    settle(w, 30)
    sizes = {}
    for worst in (False, True):
        ob = R.eval(fill_lua(), rand_ids(7 if worst else 3), worst)
        assert ob == 200, ob
        R.eval("ns.BiS:Commit()")
        o = own(R)
        wire, inflated = R.eval(SIZE_LUA.replace("local msg = ...", "local rec = ns.BiS:GetRecord() "
                                "local msg = { t = 'L', r = rec.rev, ts = rec.ts, h = rec.hash, d = rec.data }"))
        sizes[worst] = wire
        assert wire < MAX_WIRE_LEN_MEMBER and inflated < MAX_INFLATED_LEN_MEMBER, (worst, wire, inflated)
        settle(w, 6)
        c = cached(C1, RK)
        assert c and c["rev"] == o["rev"] and c["hash"] == o["hash"], "the council did not take it: %s vs %s" % (c, o)
        d = data_of(C1, RK)
        assert len(norm(d["pr"])) == 17 and len(norm(d["opr"])) == 17, d
    # a relay answer carries 8 lists: fullest lists without disabled slots, each with other items
    R.eval("__PR_E = {}")
    for i in range(8):
        R.eval(fill_lua(), rand_ids(100 + i), False)
        R.eval("ns.BiS:Commit()")
        R.eval("local i = ... local rec = ns.BiS:GetRecord() __PR_E[#__PR_E + 1] = { o = 'Member' .. i .. '-Thunderstrike', "
               "r = rec.rev, ts = rec.ts, h = rec.hash, d = ns.Util.CopyTable(rec.data) }", i)
    relay, _ = R.eval(SIZE_LUA.replace("local msg = ...", "local msg = { t = 'R', e = __PR_E }"))
    assert relay < MAX_WIRE_LEN, relay
    r.note("fullest list on the wire: %d bytes (every slot disabled too: %d); 8 of them in one relay: %d bytes"
           % (sizes[False], sizes[True], relay))
    w.assert_no_errors()


@r.case
def released_1_3_0_council_stores_relays_and_restores_it():
    old = addon_130()
    if old is None:
        r.note("SKIPPED: %s is missing" % DIST_130)
        return
    w, R, O, N = trio(c1_dir=old)
    settle(w, 30)
    assert O.eval("return ns.PRE_RAID") is None, "Councila does not run the released 1.3.0 code"
    head, phead = candidates(R, 1, 2)
    neck = candidates(R, 2, 1)[0]
    assert bis(R, "SetSlot(1, 1, 'main', ...)", head) is True
    assert bis(R, "SetSlot(0, 1, 'main', ...)", phead) is True
    assert bis(R, "SetSlot(0, 2, 'main', ...)", neck) is True
    assert bis(R, "SetSlotDisabled(0, 2, true)") is True
    assert bis(R, "AddOffSpec('Protection')") is True
    assert bis(R, "SetSlot(0, 1, 'main', ..., 'os')", head) is True
    assert bis(R, "SetSlotDisabled(0, 5, true, 'os')") is True
    R.eval("ns.BiS:Commit()")
    settle(w, 6)
    o = own(R)
    full = data_of(R)
    # stored untouched (its validator ignores the new keys, the hash covers them)
    c = cached(O, RK)
    assert c and c["rev"] == o["rev"] and c["hash"] == o["hash"] == c["live"], (c, o)
    d = data_of(O, RK)
    for k in ("pr", "px", "opr", "opx"):
        assert norm(d.get(k)) == norm(full[k]), (k, d.get(k), full[k])
    # and never a wanter of the Pre-raid picks
    assert wanters(O, phead) == [] and wanters(O, neck) == [], (wanters(O, phead), wanters(O, neck))
    assert wanters(O, head) == [RK + ":1"], wanters(O, head)
    # relayed to a council member who logs in later while the owner is offline
    R.logout()
    settle(w, 2)
    N.login()
    settle(w, 40)
    c = cached(N, RK)
    assert c and c["hash"] == o["hash"] == c["live"] and c["via"] == C1K, c
    assert norm(data_of(N, RK)["pr"]) == norm(full["pr"])
    N.logout()
    settle(w, 2)
    # restored from the old client after a reinstall
    wipe_saved(w, R)
    R.login()
    settle(w, 45)
    o2 = own(R)
    assert o2["rev"] == o["rev"] and o2["hash"] == o["hash"], (o2, o)
    d = data_of(R)
    for k in ("pr", "px", "opr", "opx"):
        assert norm(d.get(k)) == norm(full[k]), (k, d.get(k))
    w.assert_no_errors()


r.run()
