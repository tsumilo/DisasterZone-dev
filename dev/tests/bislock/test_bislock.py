"""ADDENDUM F §38: the raid leader locks / unlocks every raider's BiS list (GS lk / lkAt), on the real addon.

Covers: locking by the raid's loot authority (GS fields, one raid chat line, everyone locked incl. the leader,
BIS_LOCK_CHANGED, /dz rules), every BiS editing API refusing (one print per 3 s) while obtained / equipped /
"Mark obtained" still sync, the My BiS lock banner / disabled controls / picker refusal, forged edits from a
modified client (direct data change + commit) flagged on council clients (roster, member view, drop panel,
GetWanters) with one council-only warning, flagged players never suggested in rolls (also for a non-council
master looter through RT lc) while the council can still award them, unlock clearing everything, the lock ending
on disband / authority change / raid -> party, only the authority being able to lock (forged / party / malformed
GS), a mid-raid joiner and /reloads learning the lock, an edit made just before the lock not being flagged, and
a CDLoot 0.2 raider in a locked raid (can't be locked, but its changes are still detected).

Run: luaenv\\Scripts\\python.exe tests\\bislock\\test_bislock.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import (case, run_all, no_errors, World, Client, ExtraMember, install_helpers, menu_texts,  # noqa: E402
                     printed_since, strip_codes, tt_lines, gm_pick, menu_pick, menu_labels)
import lr_common as lr  # noqa: E402

ADDON_02 = os.path.join(TESTS, "grouprules", "addon02", "CDLoot")
REALM = "Thunderstrike"
ANNOUNCE = "DisasterZone: BiS lists are locked for this raid."
FLAG_GAP = 5          # a forged commit this long after the lock (the core accepts commits <= 3 s after it)

EVENTS_LUA = r"""
__LK = { changed = {} }
ns:On("BIS_LOCK_CHANGED", function(locked) __LK.changed[#__LK.changed + 1] = locked and 1 or 0 end)
"""


def K(name):
    return "%s-%s" % (name, REALM)


def world(names=(("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 1, "MAGE"), ("Rita", 3, "PRIEST"),
                 ("Sam", 3, "ROGUE")), council=("Bob",), **wkw):
    """Gina = GM (council), Bob = guild council, Lee = raid leader (raid-scope council), Rita / Sam = raiders."""
    w = World(**wkw)
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
        x.eval(EVENTS_LUA)
    w.tick(3)
    gm_pick(w, c["Gina"], list(council))
    return w, c


def raid(w, c, members=("Lee", "Bob", "Rita", "Sam", "Gina"), leader="Lee", tick=8, **kw):
    w.make_raid([c[n] for n in members], leader=c[leader], **kw)
    w.tick(tick)


def cand(cl, sid, n=1, klass=None):
    return cl.eval("local s, n, k = ...; return ns.ItemDB:GetCandidates(s, {maxPhase=1, class=k, usableOnly=true})[n].itemID",
                   sid, n, klass or cl.class_file)


def locked(cl):
    return cl.eval("return ns.GroupRules:IsLocked()")


def lock_events(cl):
    return cl.eval_py("return __LK.changed") or []


def said(cl, n0, needle):
    return [strip_codes(l) for l in printed_since(cl, n0) if needle in strip_codes(l)]


def forge(cl, lua_change):
    """A modified client edits its data directly (bypassing the refusing BiS APIs) and commits."""
    cl.eval("local d = ns.BiS:GetData(); " + lua_change + "; ns.BiS:Commit()")


def flag(cl, name):
    return cl.eval("return ns.Store:GetLockFlag(...)", K(name))


def tile_btn(c, sid, which="main"):
    return c.eval("local s, w = ...; return T_tile(s)[w]", sid, which)


# ------------------------------------------------------------------------------------------------------------------
@case
def raid_leader_locks_everyone_learns_it():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    raid(w, c)
    assert not any(locked(x) for x in c.values())
    assert lee.eval("return ns.GroupRules:IsAuthority()") is True
    mark, chat0 = len(w.addon_log), len(w.chat_log)
    n0 = {n: len(x.chat_frame) for n, x in c.items()}
    lee.slash("/dz lock")
    w.tick(1)
    gs = [m for m in lr.msgs_of_type(w, "GS", mark) if m["_sender"] == K("Lee")]
    assert gs and gs[-1].get("lk") is True and isinstance(gs[-1].get("lkAt"), int), gs
    assert gs[-1]["_chat_type"] == "RAID"
    ann = [e for e in w.chat_log[chat0:] if e["text"] == ANNOUNCE]
    assert len(ann) == 1 and ann[0]["chat_type"] == "RAID" and ann[0]["sender"] == K("Lee"), w.chat_log[chat0:]
    for n, x in c.items():
        assert locked(x) is True, n
        info = x.eval_py("return ns.GroupRules:GetLockInfo()")
        assert info["by"] == K("Lee") and info["at"] == gs[-1]["lkAt"], (n, info)
        assert x.eval("return (ns.BiS:IsLocked())") is True, n
        assert lock_events(x) == [1], (n, lock_events(x))
    assert said(lee, n0["Lee"], "you locked the BiS lists for this raid"), printed_since(lee, n0["Lee"])
    assert said(rita, n0["Rita"], "BiS lists are locked by Lee for this raid."), printed_since(rita, n0["Rita"])
    act = rita.eval_py("return ns.GroupRules:GetActive().values")
    assert act["lk"] is True and act["lkAt"] == gs[-1]["lkAt"], act
    # /dz rules shows it; locking again only says so (no second GS / announce)
    n1 = len(rita.chat_frame)
    rita.slash("/dz rules")
    assert said(rita, n1, "BiS lists are locked by Lee."), printed_since(rita, n1)
    mark, chat0 = len(w.addon_log), len(w.chat_log)
    n1 = len(lee.chat_frame)
    lee.slash("/dz lock")
    w.tick(1)
    assert said(lee, n1, "BiS lists are already locked.")
    assert not [e for e in w.chat_log[chat0:] if e["text"] == ANNOUNCE]
    # without roll announcements there is no raid chat line
    lee.slash("/dz unlock")
    w.tick(2)
    lee.eval("ns.DB:SetSetting('roll.announce', false)")
    chat0 = len(w.chat_log)
    lee.slash("/dz lock")
    w.tick(2)
    assert all(locked(x) for x in c.values())
    assert not [e for e in w.chat_log[chat0:] if e["text"] == ANNOUNCE]
    w.assert_no_errors()


@case
def every_edit_api_refuses_while_obtained_items_still_sync():
    w, c = world()
    rita, bob, lee = c["Rita"], c["Bob"], c["Lee"]
    head, chest, ring = cand(rita, 1), cand(rita, 5), cand(rita, 11)
    lr.seed_bis(rita, [(1, 1, "main", head), (1, 5, "main", chest), (1, 1, "alt", cand(rita, 1, 2)),
                       (0, 1, "main", head)])
    raid(w, c)
    w.tick(10)
    assert bob.eval("return ns.Store:GetCached(...) ~= nil", K("Rita"))
    lee.slash("/dz lock")
    w.tick(2)
    picks = "local d = ns.BiS:GetData() return ns.Util.Hash({ ph = d.ph, dx = d.dx, sp = d.sp, pr = d.pr, px = d.px })"
    h0 = rita.eval(picks)
    n0 = len(rita.chat_frame)
    calls = ["ns.BiS:SetSlot(1, 2, 'main', %d)" % cand(rita, 2), "ns.BiS:SetSlot(1, 1, 'main', nil)",
             "ns.BiS:ClearSlot(1, 1)", "ns.BiS:SwapMainAlt(1, 1)", "ns.BiS:CopyPhase(1, 2, true)",
             "ns.BiS:CopyPhase(1, 2, false)", "ns.BiS:ApplyTemplate(2, { [11] = { %d } }, false)" % ring,
             "ns.BiS:ClearPhase(1)", "ns.BiS:SetSpec('Shadow')", "ns.BiS:SetSpec(nil)",
             "ns.BiS:SetSlotDisabled(1, 1, true)", "ns.BiS:SetSlotDisabledAllPhases(1, true)",
             # the Pre-raid list is frozen too
             "ns.BiS:SetSlot(0, 2, 'main', %d)" % cand(rita, 2), "ns.BiS:CopyPhase(1, 0, false)",
             "ns.BiS:CopyPhase(0, 1, true)", "ns.BiS:ApplyTemplate(0, { [11] = { %d } }, false)" % ring,
             "ns.BiS:ClearPhase(0)", "ns.BiS:SetSlotDisabled(0, 1, true)", "ns.BiS:SetSlot(0, 1, 'main', %d, 'os')" % head]
    for code in calls:
        assert rita.eval("return " + code) is False, code
    h1 = rita.eval(picks)
    assert h1 == h0, "a refused call changed the list"
    assert rita.eval("return ns.BiS:IsDirty()") is False
    lines = said(rita, n0, "BiS lists are locked by Lee during the raid.")
    assert len(lines) == 1, printed_since(rita, n0)
    w.tick(3.2)
    assert rita.eval("return ns.BiS:ClearSlot(1, 1)") is False
    assert len(said(rita, n0, "BiS lists are locked by Lee during the raid.")) == 2
    # the raid leader is locked too (and told how to unlock)
    n1 = len(lee.chat_frame)
    assert lee.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", cand(lee, 1)) is False
    assert said(lee, n1, "/dz unlock"), printed_since(lee, n1)
    # obtained / equipped / manual marks still work and sync, without a "changed during lock" flag
    rev0 = bob.eval("return ns.Store:GetCached(...).rev", K("Rita"))
    rita.give_item(chest)
    w.tick(15)
    rec = bob.eval_py("local r = ns.Store:GetCached(...); return { r.rev, r.data.ob }", K("Rita"))
    assert rec[0] > rev0 and chest in (rec[1] or []), rec
    rita.equip({1: head})
    w.tick(15)
    assert bob.eval("return ns.Store:GetCached(...).data.eq[1]", K("Rita")) == head
    other = cand(rita, 1, 2)
    assert rita.eval("return ns.BiS:SetManualObtained(...)", other, True) is not False
    rita.eval("ns.BiS:Commit()")
    w.tick(10)
    assert other in (bob.eval_py("return ns.Store:GetCached(...).data.ob", K("Rita")) or [])
    assert flag(bob, "Rita") is None and flag(lee, "Rita") is None
    w.assert_no_errors()


@case
def my_bis_banner_disabled_controls_and_picker_refusal():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    lr.seed_bis(rita, [(1, 1, "main", cand(rita, 1))])
    raid(w, c)
    install_helpers(rita)
    rita.slash("/dz bis")
    w.tick(0.3)
    rita.click(tile_btn(rita, 3))
    assert rita.eval("return ns.Picker:IsOpen()") is True
    assert rita.eval("return T_card().lockBanner:IsShown()") is False
    lee.eval("ns.GroupRules:SetLocked(true)")
    w.tick(2)
    assert rita.eval("return ns.Picker:IsOpen()") is False, "the picker stayed open when the lock started"
    assert rita.eval("return T_card().lockBanner:IsShown()") is True
    assert "locked by lee" in strip_codes(rita.eval("return T_card().lockBanner.title:GetText()")).lower()
    # the picker won't open (click, API)
    rita.click(tile_btn(rita, 2))
    assert rita.eval("return ns.Picker:IsOpen()") is False
    assert rita.eval("return ns.Picker:Open(1, 2, 'main')") is False
    # tile menu: only what still works (no greyed entries), under one line that says why
    rita.click(tile_btn(rita, 1), "RightButton")
    menu = {strip_codes(e[2]).strip(): e[3] for e in menu_texts(rita.last_menu()) if e[2]}
    for label in ("Choose main...", "Choose alt...", "Clear slot", "Disable slot (P1)", "Disable in all phases"):
        assert label not in menu, (label, menu)
    assert "Locked by Lee" in menu, menu
    assert menu.get("Mark obtained") is True and menu.get("Link main in chat") is True, menu
    # tooltips mention the lock
    rita.eval("T_tile(3).main:GetScript('OnEnter')(T_tile(3).main)")
    assert any("locked during the raid" in strip_codes(l[0]) for l in tt_lines(rita)), tt_lines(rita)
    # a menu click on "Mark obtained" works while locked
    rita.menu_select("Mark obtained")
    w.tick(0.2)
    assert rita.eval("return ns.BiS:GetObtainedState(...)", cand(rita, 1)) == "manual"
    # toolbar: More stays usable for Export; its Import and Clear phase are greyed out
    assert rita.eval("return T_mybis().moreBtn:IsEnabled()") in (True, 1)
    rita.click(rita.eval("return T_mybis().moreBtn"))
    more = {strip_codes(e[2]).strip(): e[3] for e in menu_texts(rita.last_menu()) if e[2]}
    assert "Import" not in more and "Clear P1" not in more, more          # only what still works
    assert more.get("Export") is True, more
    # unlock: banner gone, controls back, the picker opens
    lee.eval("ns.GroupRules:SetLocked(false)")
    w.tick(2)
    assert rita.eval("return T_card().lockBanner:IsShown()") is False
    assert rita.eval("return T_mybis().moreBtn:IsEnabled()") in (True, 1)
    rita.click(tile_btn(rita, 2))
    assert rita.eval("return ns.Picker:IsOpen()") is True
    w.assert_no_errors()


@case
def forged_edit_is_flagged_on_council_clients_and_views():
    w, c = world()
    rita, bob, lee, sam, gina = c["Rita"], c["Bob"], c["Lee"], c["Sam"], c["Gina"]
    head, ring = cand(rita, 1), cand(rita, 11)
    lr.seed_bis(rita, [(1, 1, "main", head), (1, 11, "main", ring)])
    lr.seed_bis(sam, [(1, 1, "main", cand(sam, 1))])
    raid(w, c)
    w.tick(10)
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    n0 = {n: len(x.chat_frame) for n, x in c.items()}
    forge(rita, "d.ph[1][2] = { %d, 0 }" % cand(rita, 2))
    w.tick(10)
    for n in ("Bob", "Gina", "Lee"):                     # guild council, GM, raid leader (raid council)
        assert flag(c[n], "Rita"), n
        assert len(said(c[n], n0[n], "Rita changed their BiS list while lists were locked")) == 1, n
    assert flag(sam, "Rita") is None and not said(sam, n0["Sam"], "changed their BiS list")
    assert not said(rita, n0["Rita"], "changed their BiS list")
    # the new list is still accepted (the council sees the new pick)
    assert bob.eval("return ns.Store:GetCached(...).data.ph[1][2][1]", K("Rita")) == cand(rita, 2)
    # a later spec change: still flagged, no second warning
    forge(rita, "d.sp = 'Holy'")
    w.tick(10)
    assert len(said(bob, n0["Bob"], "Rita changed their BiS list")) == 1
    # a disabled-slot change alone is a change too (Sam)
    assert flag(bob, "Sam") is None
    forge(sam, "d.dx = { [1] = { [1] = true } }")
    w.tick(10)
    assert flag(bob, "Sam"), "a dx change during the lock is not flagged"
    # GetWanters carries the flag
    ws = bob.eval_py("local o = {} for _, x in ipairs(ns.Store:GetWanters(...)) do o[#o + 1] = { x.key, x.lockChanged or false } end return o", ring)
    assert ws == [[K("Rita"), flag(bob, "Rita")]], ws
    # Council tab: roster marker, member header, lock status
    install_helpers(bob)
    bob.slash("/dz council")
    w.tick(0.5)
    warn = bob.eval_py("""
      local o = {}
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        local d = rawget(r, 'cdlData')
        if d then o[d.key] = r.lockWarn:IsShown() and 1 or 0 end
      end
      return o""")
    assert warn.get(K("Rita")) == 1 and warn.get(K("Sam")) == 1 and warn.get(K("Bob"), 0) == 0, warn
    assert bob.eval("return DisasterZoneCouncilPanel.lockStatus:IsShown()") is True
    assert "Locked by Lee" in strip_codes(bob.eval("return DisasterZoneCouncilPanel.lockStatus.text:GetText()"))
    bob.eval("ns.CouncilUI:ShowMember(...)", K("Rita"))
    w.tick(0.3)
    assert bob.eval("return DisasterZoneCouncilPanel.memberView.lockFlag:IsShown()") is True
    assert "changed during lock" in strip_codes(bob.eval("return DisasterZoneCouncilPanel.memberView.lockFlag.text:GetText()"))
    # drop panel: the candidate row carries the warning icon + tooltip line
    bob.eval("ns.DropPanel:ShowDrop({ i = { ... }, b = '', ts = GetServerTime(), from = UnitName('player') })", ring)
    w.tick(0.5)
    st = bob.eval_py("""
      local o = {}
      for _, r in ipairs(ns.DropPanel.blocks[1].rows) do
        if r:IsShown() and r.data then o[#o + 1] = { r.data.key, r.status:GetText() or '' } end
      end
      return o""")
    assert [x for x in st if x[0] == K("Rita") and "AlertNew" in x[1]], st
    w.assert_no_errors()


@case
def pre_raid_change_during_the_lock_is_not_flagged():
    """The council never sees the Pre-raid list, and the lock's picks hash leaves it out (so 1.3.0 and newer council
    clients agree): a list that arrives during the lock with only Pre-raid changes is accepted and not flagged."""
    w, c = world()
    rita, bob, lee = c["Rita"], c["Bob"], c["Lee"]
    lr.seed_bis(rita, [(1, 1, "main", cand(rita, 1)), (0, 2, "main", cand(rita, 2))])
    raid(w, c)
    w.tick(10)
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    n0 = len(bob.chat_frame)
    rev0 = bob.eval("return ns.Store:GetCached(...).rev", K("Rita"))
    forge(rita, "d.pr = { [2] = { %d, 0 }, [3] = { %d, 0 } }; d.px = { [4] = true }" % (cand(rita, 2, 2), cand(rita, 3)))
    w.tick(10)
    rec = bob.eval_py("local r = ns.Store:GetCached(...) return { r.rev, r.data.pr[3][1] }", K("Rita"))
    assert rec[0] > rev0 and rec[1] == cand(rita, 3), rec
    for n in ("Bob", "Gina", "Lee"):
        assert flag(c[n], "Rita") is None, n
    assert not said(bob, n0, "changed their BiS list"), printed_since(bob, n0)
    w.assert_no_errors()


@case
def flagged_player_is_not_suggested_but_can_be_awarded():
    w, c = world()
    rita, bob, lee, sam = c["Rita"], c["Bob"], c["Lee"], c["Sam"]
    item = cand(rita, 11, 1, "PRIEST")
    lr.seed_bis(rita, [(1, 11, "main", item)])
    lr.seed_bis(sam, [(1, 11, "main", item)])
    raid(w, c)
    w.tick(10)
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    forge(rita, "d.ph[1][12] = { %d, 0 }" % item)
    w.tick(10)
    assert flag(bob, "Rita")
    # the council member opens the drop in the drop panel and starts the roll there
    install_helpers(bob)
    bob.eval("ns.DropPanel:ShowDrop({ i = { ... }, b = '', ts = GetServerTime(), from = UnitName('player') })", item)
    w.tick(0.5)
    bob.eval("ns.DropPanel:StartRoll(...)", item)
    w.tick(1)
    sid = bob.eval("local s = ns.Roll:GetActive(); return s and s.id")
    assert sid, "no roll session"
    w.player_roll(rita, 99)
    w.player_roll(sam, 10)
    w.tick(1)
    res = bob.eval_py("local o = {} for i, x in ipairs(ns.Roll:GetResults(...)) do "
                      "o[i] = { x.key, x.roll or 0, x.suggested and 1 or 0, x.lockChanged and 1 or 0 } end return o", sid)
    top = res[0]
    assert top[0] == K("Rita") and top[1] == 99 and top[2] == 0 and top[3] == 1, res
    sug = [x for x in res if x[2]]
    assert len(sug) == 1 and sug[0][0] == K("Sam"), res
    # the drop panel roll row shows the marker; the council can still award Rita
    rows = bob.eval_py("""
      local o = {}
      for _, b in ipairs(ns.DropPanel.blocks or {}) do
        for _, r in ipairs(b.rows or {}) do
          if r:IsShown() and r.data then o[#o + 1] = { r.data.key, r.tag and r.tag:GetText() or '', r.status and r.status:GetText() or '' } end
        end
      end
      return o""")
    assert [x for x in rows if x[0] == K("Rita") and ("AlertNew" in x[1] or "AlertNew" in x[2])], rows
    bob.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    bob.eval("ns.Roll:Award(...)", sid, K("Rita"))
    pops = bob.popups()
    which = next(p for p in ("DISASTERZONE_CONFIRM_AWARD", "DISASTERZONE_GIVE_ITEM") if p in pops)
    bob.accept_popup(which)
    w.tick(2)
    ses = bob.eval_py("local s = ns.Roll:Get(...); return { s.state, s.winner }", sid)
    assert ses == ["awarded", K("Rita")], ses
    # (the awarded session keeps its rows as they were at the award, flag included)
    res = bob.eval_py("local o = {} for i, x in ipairs(ns.Roll:GetResults(...)) do o[i] = { x.key, x.lockChanged and 1 or 0 } end return o", sid)
    assert [x for x in res if x[0] == K("Rita")][0][1] == 1, res
    # unlocked: the flag is gone and a new roll suggests the top roll again
    lee.slash("/dz unlock")
    w.tick(2)
    assert bob.eval("return ns.Roll:Start(...)", item) is not False
    w.tick(1)
    sid2 = bob.eval("local s = ns.Roll:GetActive(); return s and s.id")
    assert sid2 and sid2 != sid, (sid, sid2)
    w.player_roll(rita, 90)
    w.player_roll(sam, 20)
    w.tick(1)
    res = bob.eval_py("local o = {} for i, x in ipairs(ns.Roll:GetResults(...)) do "
                      "o[i] = { x.key, x.suggested and 1 or 0, x.lockChanged and 1 or 0 } end return o", sid2)
    # (Rita already won the ring tonight, so Sam ranks first now; nobody is flagged any more)
    assert all(x[2] == 0 for x in res) and res[0][1] == 1, res
    w.assert_no_errors()


@case
def non_council_master_looter_gets_the_flags_via_rt():
    # 1.3: a master looter from the guild is council of the raid while it runs the loot council (it holds the lists
    # and flags itself), so the non-council master looter here is a pug, who gets the tiers and flags by RT.
    w, c = world()
    rita, bob, lee, gina = c["Rita"], c["Bob"], c["Lee"], c["Gina"]
    sam = Client(w, "Pugml", guild=None, class_file="ROGUE")
    sam.load_addon()
    sam.eval(EVENTS_LUA)
    w.tick(2)
    item = cand(rita, 11, 1, "PRIEST")
    lr.seed_bis(rita, [(1, 11, "main", item)])
    lr.seed_bis(gina, [(1, 11, "main", item)])
    w.make_raid([c[n] for n in ("Lee", "Bob", "Rita", "Sam", "Gina")] + [sam], leader=lee, master_looter=sam)
    w.tick(20)
    assert sam.eval("return ns.Guild:AmICouncil(true)") is False
    assert bob.eval("return ns.Guild:IsCouncil(..., true)", K("Pugml")) is False
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    forge(rita, "d.ph[1][12] = { %d, 0 }" % item)
    w.tick(10)
    assert flag(bob, "Rita") and flag(sam, "Rita") is None
    mark = len(w.addon_log)
    sam.eval("return ns.Roll:Start(...)", item)
    w.tick(2)
    sid = sam.eval("local s = ns.Roll:GetActive(); return s and s.id")
    assert sid, "the ML could not start a roll"
    rts = lr.msgs_of_type(w, "RT", mark)
    assert any((m.get("lc") or {}).get(K("Rita")) == 1 for m in rts), rts
    w.player_roll(rita, 99)
    w.player_roll(gina, 10)
    w.tick(1)
    res = sam.eval_py("local o = {} for i, x in ipairs(ns.Roll:GetResults(...)) do "
                      "o[i] = { x.key, x.suggested and 1 or 0, x.lockChanged and 1 or 0 } end return o", sid)
    assert [x[0] for x in res if x[1]] == [K("Gina")], res
    assert [x for x in res if x[0] == K("Rita") and x[2]], res
    w.assert_no_errors()


@case
def unlock_clears_flags_and_editing_works_again():
    w, c = world()
    rita, bob, lee = c["Rita"], c["Bob"], c["Lee"]
    lr.seed_bis(rita, [(1, 1, "main", cand(rita, 1))])
    raid(w, c)
    w.tick(10)
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    forge(rita, "d.ph[1][2] = { %d, 0 }" % cand(rita, 2))
    w.tick(10)
    assert flag(bob, "Rita")
    install_helpers(bob)
    bob.slash("/dz council")
    w.tick(0.5)
    n0 = {n: len(x.chat_frame) for n, x in c.items()}
    lee.slash("/dz unlock")
    w.tick(2)
    for n, x in c.items():
        assert locked(x) is False, n
        assert x.eval("return ns.GroupRules:GetLockInfo()") is None, n
        assert lock_events(x) == [1, 0], (n, lock_events(x))
        assert said(x, n0[n], "BiS lists are unlocked."), n
    assert flag(bob, "Rita") is None and bob.eval("return next(ns.Store:GetLockFlags())") is None
    warn = bob.eval_py("local o = {} for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do "
                       "local d = rawget(r, 'cdlData') if d then o[d.key] = r.lockWarn:IsShown() and 1 or 0 end end return o")
    assert warn.get(K("Rita")) == 0, warn
    assert bob.eval("return DisasterZoneCouncilPanel.lockStatus:IsShown()") is False
    assert rita.eval("return ns.BiS:SetSlot(1, 3, 'main', ...)", cand(rita, 3)) is True
    assert rita.eval("return ns.BiS:SetSlotDisabled(1, 4, true)") is True
    # a new lock starts clean: the earlier change is not flagged again
    lee.slash("/dz lock")
    w.tick(10)
    assert flag(bob, "Rita") is None
    w.assert_no_errors()


@case
def lock_ends_on_disband_authority_change_and_party():
    w, c = world()
    lee, rita, bob, sam = c["Lee"], c["Rita"], c["Bob"], c["Sam"]
    raid(w, c)
    lee.slash("/dz lock")
    w.tick(2)
    assert lee.eval("return ns.db.groupLock ~= nil") is True
    w.disband()
    w.tick(3)
    for n, x in c.items():
        assert locked(x) is False, n
    assert lee.eval("return ns.db.groupLock") is None
    assert rita.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", cand(rita, 1)) is True
    # a new raid starts unlocked
    raid(w, c)
    assert not any(locked(x) for x in c.values())
    # the lead moves to Bob: Lee's lock ends everywhere
    lee.slash("/dz lock")
    w.tick(2)
    assert all(locked(x) for x in c.values())
    raid(w, c, leader="Bob", tick=10)
    assert bob.eval("return ns.GroupRules:IsAuthority()") is True
    for n, x in c.items():
        assert locked(x) is False, n
    assert lee.eval("return ns.db.groupLock") is None
    # the raid becomes a party: the lock ends (and a party can't lock)
    bob.slash("/dz lock")
    w.tick(2)
    assert locked(rita) is True
    w.make_party([bob, rita, sam])
    w.tick(8)
    for n in ("Bob", "Rita", "Sam"):
        assert locked(c[n]) is False, n
    ok, err = bob.eval("return ns.GroupRules:SetLocked(true)")
    assert ok is False and "raid" in err, (ok, err)
    w.assert_no_errors()


@case
def only_the_authority_can_lock_forged_party_and_malformed_gs():
    w, c = world()
    lee, rita, sam, bob = c["Lee"], c["Rita"], c["Sam"], c["Bob"]
    raid(w, c)
    ok, err = rita.eval("return ns.GroupRules:SetLocked(true)")
    assert ok is False and "raid leader" in err, (ok, err)
    n0 = len(rita.chat_frame)
    rita.slash("/dz lock")
    assert said(rita, n0, "only the raid leader"), printed_since(rita, n0)
    # council members who are not the authority can't either
    assert bob.eval("return ns.GroupRules:SetLocked(true)")[0] is False
    w.tick(1)
    assert not any(locked(x) for x in c.values())
    # a forged GS with lk from a non-authority raider is ignored
    sam.eval("return ns.Comm:Send({ t = 'GS', v = 50, rd = 30, q = 4, dq = 3, lk = true, lkAt = 100 }, 'RAID', nil, 'alert')")
    w.tick(2)
    assert not any(locked(x) for x in c.values())
    # UI: the lock buttons are for the authority only
    for x in (lee, bob, rita):
        install_helpers(x)
        x.slash("/dz settings")
        w.tick(0.3)
    assert lee.eval("return ns.SettingsUI.lockBtn:IsShown() and ns.SettingsUI.lockBtn:IsEnabled()") in (True, 1)
    assert lee.eval("return ns.SettingsUI.lockBtn:GetText()") == "Lock BiS lists"
    assert rita.eval("return ns.SettingsUI.lockBtn:IsShown()") is False, "no disabled button: the line says why"
    assert "raid leader only" in strip_codes(rita.eval("return ns.SettingsUI:LockStatusText()"))
    bob.slash("/dz council")
    lee.slash("/dz council")
    w.tick(0.5)
    assert lee.eval("return DisasterZoneCouncilPanel.lockBtn:IsShown()") is True
    assert bob.eval("return DisasterZoneCouncilPanel.lockBtn:IsShown()") is False
    # the drop panel footer: "Lock lists" for the leader only
    for x in (lee, bob):
        x.eval("ns.DropPanel:ShowDrop({ i = { 28766 }, b = '', ts = GetServerTime(), from = UnitName('player') })")
    w.tick(0.3)
    assert lee.eval("return ns.DropPanel.lockBtn:IsShown()") is True
    assert lee.eval("return ns.DropPanel.lockBtn:GetText()") == "Lock lists"
    assert bob.eval("return ns.DropPanel.lockBtn:IsShown()") is False
    # the Settings button locks; the status follows
    lee.slash("/dz settings")
    w.tick(0.3)
    lee.click(lee.eval("return ns.SettingsUI.lockBtn"))
    w.tick(2)
    assert all(locked(x) for x in c.values())
    assert lee.eval("return ns.SettingsUI.lockBtn:GetText()") == "Unlock BiS lists"
    assert "Locked by" in strip_codes(rita.eval("return ns.SettingsUI:LockStatusText()"))
    assert bob.eval("return DisasterZoneCouncilPanel.lockStatus:IsShown()") is True
    lee.click(lee.eval("return ns.SettingsUI.lockBtn"))
    w.tick(2)
    assert not any(locked(x) for x in c.values())
    # a malformed lk / lkAt from the real authority is dropped, the rules themselves still apply (1.3: a lock counts
    # only with a running session that has the loot council)
    sess = "rs = ns.GroupRules:GetSession().id, rsAt = ns.GroupRules:GetSession().at, rf = 'lr'"
    lee.eval("return ns.Comm:Send({ t = 'GS', v = 900, rd = 45, q = 4, dq = 3, lk = 'yes', lkAt = -5, %s }, 'RAID', nil, "
             "'alert')" % sess)
    w.tick(2)
    assert rita.eval("return ns.GroupRules:GetActive().values.rd") == 45
    assert locked(rita) is False
    lee.eval("return ns.Comm:Send({ t = 'GS', v = 901, rd = 45, q = 4, dq = 3, lk = true, lkAt = 'x', %s }, 'RAID', nil, "
             "'alert')" % sess)
    w.tick(2)
    assert locked(rita) is True, "lk without a valid lkAt still locks (time of first sight)"
    assert isinstance(rita.eval_py("return ns.GroupRules:GetLockInfo()")["at"], int)
    w.assert_no_errors()


@case
def the_lock_needs_a_raid_with_the_loot_council_and_is_its_lock_feature():
    # 1.3: the BiS lock needs a running raid session with the loot council, and the session's lock feature is the lock
    # (one truth: the session bar, its tooltip and the Options window agree); ending the raid or switching the loot
    # council off unlocks; receivers don't count a lock without such a session either
    w, c = world()
    w.auto_session = False
    lee, rita = c["Lee"], c["Rita"]
    raid(w, c)

    def feats(x):
        return x.eval_py("local f = ns.GroupRules:GetSessionFeatures(); return f and { f.loot, f.rolls, f.lock }")

    # no raid session: no lock (the slash command, the buttons)
    n0 = len(lee.chat_frame)
    lee.slash("/dz lock")
    w.tick(2)
    assert said(lee, n0, "start the raid"), printed_since(lee, n0)
    assert not any(locked(x) for x in c.values())
    assert lee.eval("return ns.UI:CanSetBiSLock()") is False
    # a raid without the loot council: the lock feature is off too, and nothing locks
    res = lee.eval_py("local ok, e = ns.GroupRules:SetSession(true, nil, { loot = false, rolls = true, lock = true }); "
                      "return { ok = ok, e = e }")
    assert res["ok"] is True, res
    w.tick(3)
    for x in c.values():
        assert feats(x) == [False, True, False] and locked(x) is False, (x.name, feats(x))
    n0 = len(lee.chat_frame)
    lee.slash("/dz lock")
    w.tick(2)
    assert said(lee, n0, "needs the loot council"), printed_since(lee, n0)
    assert not any(locked(x) for x in c.values()) and lee.eval("return ns.UI:CanSetBiSLock()") is False
    # with the loot council: /dz lock locks, and the session's lock feature says so everywhere (Options ticked)
    assert lee.eval_py("return { ns.GroupRules:SetSessionFeatures({ loot = true, rolls = true, lock = false }) }")[0]
    w.tick(3)
    assert lee.eval("return ns.UI:CanSetBiSLock()") is True
    lee.slash("/dz lock")
    w.tick(2)
    for x in c.values():
        assert locked(x) is True and feats(x) == [True, True, True], (x.name, feats(x))
    assert "BiS lists locked" in rita.eval("return ns.SessionBar:DescribeFeatures(ns.GroupRules:GetSessionFeatures())")
    lee.eval("ns.SessionBar:OpenOptions()")
    w.tick(0.2)
    assert lee.eval("return ns.SessionBar:GetStartWindow().boxes.lock:GetChecked()") is True
    lee.click(lee.eval("return ns.SessionBar:GetStartWindow().startBtn"))          # Apply as it is: still locked
    w.tick(3)
    assert all(locked(x) for x in c.values())
    # /dz unlock: the feature follows
    lee.slash("/dz unlock")
    w.tick(2)
    for x in c.values():
        assert locked(x) is False and feats(x) == [True, True, False], (x.name, feats(x))
    # switching the loot council off unlocks
    lee.slash("/dz lock")
    w.tick(2)
    assert all(locked(x) for x in c.values())
    assert lee.eval_py("return { ns.GroupRules:SetSessionFeatures({ loot = false, rolls = true, lock = true }) }")[0]
    w.tick(3)
    for x in c.values():
        assert locked(x) is False and feats(x) == [False, True, False], (x.name, feats(x))
    # the leader's /reload keeps the lock with its session; End raid unlocks
    lee.eval_py("return { ns.GroupRules:SetSessionFeatures({ loot = true, rolls = true, lock = true }) }")
    w.tick(3)
    lee.relog()
    w.tick(12)
    assert all(locked(x) for x in c.values())
    assert lee.eval("return ns.RaidLog:End()") is True
    w.tick(3)
    assert not any(locked(x) for x in c.values()) and lee.eval("return ns.db.groupLock") is None
    n0 = len(lee.chat_frame)
    lee.slash("/dz lock")
    assert said(lee, n0, "start the raid") and not locked(rita)
    # receivers count a lock only with such a session (an older raid leader's lock without one, or without the council)
    gs = "return ns.Comm:Send({ t = 'GS', v = %d, rd = 30, q = 4, dq = 3, lk = true, lkAt = GetServerTime()%s }, 'RAID', nil, 'alert')"
    lee.eval(gs % (950, ""))
    w.tick(2)
    assert locked(rita) is False
    lee.eval(gs % (951, ", rs = 'Lee-1', rsAt = GetServerTime() - 5, rf = 'r'"))
    w.tick(2)
    assert locked(rita) is False and rita.eval("return ns.GroupRules:GetSession() ~= nil") is True
    lee.eval(gs % (952, ", rs = 'Lee-1', rsAt = GetServerTime() - 5, rf = 'lr'"))
    w.tick(2)
    assert locked(rita) is True and rita.eval_py("return ns.GroupRules:GetSessionFeatures().lock") is True
    w.assert_no_errors()


@case
def party_gs_with_lk_is_ignored():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    w.make_party([lee, rita])
    w.tick(8)
    assert lee.eval("return ns.GroupRules:SetLocked(true)")[0] is False
    lee.eval("return ns.Comm:Send({ t = 'GS', v = 77, rd = 30, q = 4, dq = 3, dm = false, lk = true, lkAt = GetServerTime() }, 'PARTY', nil, 'alert')")
    w.tick(2)
    assert locked(rita) is False and rita.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", cand(rita, 1)) is True
    w.assert_no_errors()


@case
def ml_is_the_authority_when_the_leader_has_no_cdloot():
    w, c = world(names=(("Gina", 0, "PALADIN"), ("Mel", 3, "HUNTER"), ("Bob", 1, "MAGE"), ("Rita", 3, "PRIEST")))
    mel, rita = c["Mel"], c["Rita"]
    w.make_raid([c["Gina"], mel, c["Bob"], rita], master_looter=mel, leader="Norl",
                extra_members=[ExtraMember("Norl", "WARRIOR")])
    w.tick(10)
    assert mel.eval("return ns.GroupRules:IsAuthority()") is True, mel.eval("return ns.GroupRules:GetAuthority()")
    ok = mel.eval("return ns.GroupRules:SetLocked(true)")
    assert ok is True or (isinstance(ok, tuple) and ok[0] is True), ok
    w.tick(2)
    assert locked(rita) is True and rita.eval_py("return ns.GroupRules:GetLockInfo()")["by"] == K("Mel")
    w.assert_no_errors()


@case
def mid_raid_joiner_and_reloads_learn_the_lock():
    w, c = world(names=(("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 1, "MAGE"), ("Rita", 3, "PRIEST"),
                        ("Sam", 3, "ROGUE"), ("Cou", 1, "DRUID")), council=("Bob", "Cou"))
    lee, rita, sam, bob, cou = c["Lee"], c["Rita"], c["Sam"], c["Bob"], c["Cou"]
    lr.seed_bis(sam, [(1, 1, "main", cand(sam, 1))])
    raid(w, c, members=("Lee", "Bob", "Rita", "Gina"))
    lee.slash("/dz lock")
    w.tick(2)
    # a raider and a council member join mid-raid: GQ -> the leader's GS
    mark = len(w.addon_log)
    raid(w, c, members=("Lee", "Bob", "Rita", "Gina", "Sam", "Cou"), tick=10)
    assert lr.msgs_of_type(w, "GQ", mark), "the joiners did not ask for the rules"
    assert locked(sam) is True and locked(cou) is True
    assert sam.eval("return ns.BiS:SetSlot(1, 2, 'main', ...)", cand(sam, 2)) is False
    # the council joiner watches the joiner's list too (snapshot from the list it gets)
    w.tick(20)
    assert cou.eval("return ns.Store:GetCached(...) ~= nil", K("Sam"))
    forge(sam, "d.ph[1][3] = { %d, 0 }" % cand(sam, 3))
    w.tick(10)
    assert flag(cou, "Sam") and flag(bob, "Sam"), (flag(cou, "Sam"), flag(bob, "Sam"))
    # a raider /reloads: locked again after the query
    rita.relog()
    w.tick(10)
    assert locked(rita) is True
    assert rita.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", cand(rita, 1)) is False
    # the leader /reloads: the lock is kept (saved) and still announced to the raid
    lee.relog()
    w.tick(10)
    assert locked(lee) is True and locked(rita) is True
    info = rita.eval_py("return ns.GroupRules:GetLockInfo()")
    assert info["by"] == K("Lee"), info
    # the council member /reloads during the lock: flags are memory-only, but it still watches
    bob.relog()
    w.tick(20)
    assert locked(bob) is True
    forge(sam, "d.ph[1][4] = { %d, 0 }" % cand(sam, 4))
    w.tick(10)
    assert flag(bob, "Sam"), "a council member that reloaded during the lock no longer detects changes"
    w.assert_no_errors()


SET_LISTS = r"""
-- Replaces the shipped Paladin Holy list (Data/BiSLists.lua) with P1 = the given { item, slot name, rank } rows
local names = { Head = 1, Neck = 2, Shoulder = 3, Back = 4, Chest = 5, Wrist = 6, Hands = 7, Waist = 8, Legs = 9,
                Feet = 10, Ring = 11, Trinket = 12, ["Main Hand"] = 13, ["Off Hand"] = 14, ["Two Hand"] = 15 }
local parts = {}
for _, e in ipairs(... or {}) do
  parts[#parts + 1] = names[e[2]] .. ":" .. e[1] .. (e[3] == "BIS" and "*" or "")
end
ns.Data.BiSLists.PaladinHoly = { [1] = table.concat(parts, ",") }
ns.Loon:ClearCache()
"""


@case
def popups_accepted_after_the_lock_started_change_nothing():
    # "Replace all" (LoonBestInSlot) and "Clear phase" ask first; accepting after the lock started must neither
    # change the list nor claim it did.
    w = World()
    gina = Client(w, "Gina", guild_rank=0, class_file="PRIEST")
    lee = Client(w, "Lee", guild_rank=3, class_file="WARRIOR")
    pal = Client(w, "Pal", guild_rank=3, class_file="PALADIN")
    for x in (gina, lee, pal):
        x.load_addon()
    w.tick(3)
    head = cand(pal, 1)
    lr.seed_bis(pal, [(1, 1, "main", head)])
    pal.eval(SET_LISTS, [[cand(pal, 1, 2), "Head", "BIS"]])
    w.make_raid([lee, gina, pal], leader=lee)
    w.tick(8)
    install_helpers(pal)
    pal.slash("/dz bis")
    w.tick(0.3)
    assert pal.eval("return ns.BiS:GetSpec()") == "Holy"
    sug = pal.eval("return T_dropdown(T_mybis(), 'Suggest')")
    pal.dropdown_menu(sug)
    pal.menu_select("Replace all (confirm)")
    assert "DISASTERZONE_REPLACE_TEMPLATE" in pal.popups()
    pal.click(pal.eval("return T_mybis().moreBtn"))
    menu_pick(pal, "Clear P1")
    assert "DISASTERZONE_CLEAR_PHASE" in pal.popups()
    lee.slash("/dz lock")
    w.tick(2)
    n0 = len(pal.chat_frame)
    pal.accept_popup("DISASTERZONE_REPLACE_TEMPLATE")
    pal.accept_popup("DISASTERZONE_CLEAR_PHASE")
    w.tick(0.5)
    assert pal.eval("return ns.BiS:GetSlot(1, 1)") == head
    lines = printed_since(pal, n0)
    assert not [l for l in lines if "Replaced P1" in l], lines
    assert [l for l in lines if "locked by Lee" in strip_codes(l)], lines
    w.assert_no_errors()


@case
def reload_with_an_undetected_spec_is_not_flagged():
    # A raider whose spec was never detected (sp == "") /reloads inside a locked raid: the login spec detection
    # waits for the raid's rules and then leaves the locked list alone (it used to fill the spec 3 s after the
    # login, before the lock was known, and the council flagged the raider).
    w, c = world()
    rita, bob, lee = c["Rita"], c["Bob"], c["Lee"]
    lr.seed_bis(rita, [(1, 1, "main", cand(rita, 1))])
    rita.eval("ns.BiS:SetSpec(''); ns.BiS:Commit()")
    raid(w, c)
    w.tick(10)
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    rita.relog()
    w.tick(30)
    assert locked(rita) is True
    assert rita.eval("return ns.BiS:GetData().sp") == ""
    assert flag(bob, "Rita") is None and flag(lee, "Rita") is None
    # unlocked (and in a raid without a lock) the spec is detected after the rules arrive
    lee.slash("/dz unlock")
    w.tick(2)
    rita.relog()
    w.tick(30)
    assert rita.eval("return ns.BiS:GetData().sp") != "", "the spec was not detected once the raid was unlocked"
    # outside a group it is detected right away
    w.disband()
    w.tick(2)
    rita.eval("ns.BiS:SetSpec(''); ns.BiS:Commit()")
    rita.relog()
    w.tick(4)
    assert rita.eval("return ns.BiS:GetData().sp") != ""
    w.assert_no_errors()


@case
def edit_just_before_the_lock_is_not_flagged():
    w, c = world()
    rita, bob, lee = c["Rita"], c["Bob"], c["Lee"]
    lr.seed_bis(rita, [(1, 1, "main", cand(rita, 1))])
    raid(w, c)
    w.tick(10)
    rev0 = bob.eval("return ns.Store:GetCached(...).rev", K("Rita"))
    assert rita.eval("return ns.BiS:SetSlot(1, 2, 'main', ...)", cand(rita, 2)) is True   # pending (8 s debounce)
    w.tick(1)
    lee.slash("/dz lock")
    w.tick(10)
    assert locked(rita) is True and rita.eval("return ns.BiS:IsDirty()") is False
    assert bob.eval("return ns.Store:GetCached(...).rev", K("Rita")) > rev0, "the pending edit was not committed"
    assert flag(bob, "Rita") is None and flag(lee, "Rita") is None
    forge(rita, "d.ph[1][3] = { %d, 0 }" % cand(rita, 3))
    w.tick(10)
    assert flag(bob, "Rita"), "a later change is not flagged"
    w.assert_no_errors()


@case
def cdloot_02_raider_in_a_locked_raid():
    assert os.path.exists(os.path.join(ADDON_02, "CDLoot.toc")), "missing the CDLoot 0.2 fixture: %s" % ADDON_02
    w = World()
    gina = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    lee = Client(w, "Lee", guild_rank=3, class_file="WARRIOR")
    bob = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    old = Client(w, "Old", guild_rank=3, class_file="PRIEST", addon_dir=ADDON_02)
    for x in (gina, lee, bob, old):
        x.load_addon()
    w.tick(3)
    gm_pick(w, gina, ["Bob"])
    lr.seed_bis(old, [(1, 1, "main", cand(old, 1))])
    w.make_raid([lee, gina, bob, old], leader=lee)
    w.tick(20)
    old.slash("/cdl sync")
    w.tick(20)
    assert bob.eval("return ns.Store:GetCached(...) ~= nil", K("Old"))
    lee.slash("/dz lock")
    w.tick(FLAG_GAP)
    assert locked(bob) and locked(gina)
    # the old client knows nothing of the lock: it still edits, and the council sees that
    assert old.eval("return ns.BiS:SetSlot(1, 2, 'main', ...)", cand(old, 2)) is True
    old.eval("ns.BiS:Commit()")
    w.tick(15)
    assert flag(bob, "Old"), "a 0.2 raider's change during the lock is not flagged"
    lee.slash("/dz unlock")
    w.tick(2)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
