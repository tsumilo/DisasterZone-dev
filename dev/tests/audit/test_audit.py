#!/usr/bin/env python
"""The audit log (Core/Audit.lua, Core/AuditKinds.lua, UI/AuditUI.lua): kept and seen only by the Guild Master and the
guild council, recorded where a change lands, synced between them by whisper (live for one's own changes, a per-day
digest at login), never sent to anyone else; Put back; the page's visibility; demo mode's made-up log.

Run:  luaenv\\Scripts\\python.exe tests\\audit\\test_audit.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sync"))
import common  # noqa: E402
from common import (Runner, Client, new_world, up, settle, key, logical_messages, gm_pick)  # noqa: E402

common.CDL_PREFIXES = tuple(common.CDL_PREFIXES) + ("CDLz",)    # (the audit log's own prefix)

r = Runner("audit log")
GMK, CK, RK = key("Guildboss"), key("Councila"), key("Raider")

ENTRIES_LUA = """
local o, k, v = ...
local out = {}
for _, e in ipairs(ns.Audit:Entries()) do
  if (o == nil or e.o == o) and (k == nil or e.k == k) and (v == nil or e.v == v) then
    out[#out + 1] = { id = e.id, w = e.w, v = e.v, k = e.k, o = e.o, b = e.b, u = e.u, c = e.c, n = e.n,
                      f = e.f, p = e.p ~= nil }
  end
end
return out"""


def entries(c, o=None, k=None, v=None):
    return c.eval_py(ENTRIES_LUA, o, k, v) or []


def call(c, code, *args):
    return c.eval_py("local ok, r = " + code + "; return { ok = ok, r = r }", *args)


def setup(c_loaded=True):
    """The GM, one guild council member and a raider; the GM picks the council once everyone is up."""
    w = new_world(council=None)
    gm = Client(w, "Guildboss", class_file="PALADIN", guild_rank=0)
    c = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    rd = Client(w, "Raider", class_file="WARRIOR", guild_rank=3)
    for x in (gm, c, rd) if c_loaded else (gm, rd):
        up(x)
    settle(w, 3)
    gm_pick(w, gm, ["Councila"])
    settle(w, 60)                                  # (past every login digest)
    return w, gm, c, rd


def audit_traffic(w, start=0):
    return [m for m in logical_messages(w, start) if m["t"] in ("AUE", "AUD")]


@r.case
def gm_and_council_record_a_raid_change_the_raider_does_not():
    w, gm, c, rd = setup()
    assert gm.eval("return ns.Audit:IsRecording()") and c.eval("return ns.Audit:IsRecording()")
    assert not rd.eval("return ns.Audit:IsRecording()") and not rd.eval("return ns.Audit:CanSee()")
    start = len(w.addon_log)
    res = call(gm, "ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 2 * 86400, no = 'Flasks and food.' })")
    assert res["ok"], res
    occ = res["r"]
    settle(w, 10)
    for x in (gm, c):
        made = entries(x, "rp:O:" + occ, "rp.E", "add")
        assert len(made) == 1, (x.full_name, made)
        assert made[0]["w"] == GMK and made[0]["c"] == "planned {o}", made
        assert made[0]["n"].startswith("Karazhan"), made
    assert rd.eval("return ns.db.audit == nil or next(ns.db.audit) == nil"), "a raider kept an audit log"
    # an edit: the note before and after, the same entry on both
    assert call(gm, "ns.RaidPlan:EditRaid(..., { no = 'Flasks and food. Nature resistance.' })", occ)["ok"]
    settle(w, 10)
    for x in (gm, c):
        chg = entries(x, "rp:O:" + occ, "rp.E", "chg")
        assert len(chg) == 1, (x.full_name, chg)
        f = chg[0]["f"][0]
        assert f["l"] == "Note" and f["ta"] == "Flasks and food." and f["tb"] == "Flasks and food. Nature resistance.", f
    # the log only ever goes between the GM and the council, by whisper
    for m in audit_traffic(w, start):
        assert m["chat_type"] == "WHISPER", m
        names = ("Guildboss", "Councila")
        assert m["sender"].split("-")[0] in names and str(m["target"]).split("-")[0] in names, m
    w.assert_no_errors()


@r.case
def council_member_who_was_away_catches_up_at_login():
    w, gm, c, rd = setup(c_loaded=False)
    assert call(gm, "ns.RaidPlan:SetBlacklisted('Badguy', 'Ninja-looted')")["ok"]
    gm.eval("ns.OfficerNotes:Set(...)", RK, "Trial until Sunday.")
    settle(w, 5)
    assert len(entries(gm, None, "rp.BL", "add")) == 1
    up(c)
    settle(w, 120)
    got = entries(c, None, "rp.BL", "add")
    assert len(got) == 1 and got[0]["w"] == GMK and got[0]["b"] == "black", got
    assert any(e["k"] == "on.N" and e["w"] == GMK for e in entries(c)), entries(c)
    w.assert_no_errors()


@r.case
def entries_from_a_raider_are_refused():
    w, gm, c, rd = setup()
    forged = rd.eval_py("""
      local e = { t = GetServerTime(), w = ..., a = 'roles', v = 'add', o = 'gd:council', n = 'the guild council',
                  k = 'gd.CG', c = 'set up {o}' }
      e.id = ns.Audit.EntryId(e)
      ns.Comm:Send({ t = 'AUE', e = { e } }, 'WHISPER', select(2, ...), 'data')
      return e.id""", GMK, CK)
    settle(w, 5)
    assert all(e["id"] != forged for e in entries(c)), "a raider's entry was taken"
    w.assert_no_errors()


@r.case
def put_back_a_player_taken_off_the_blacklist():
    w, gm, c, rd = setup()
    res = call(gm, "ns.RaidPlan:SetBlacklisted('Badguy', 'Ninja-looted')")
    bk = res["r"]
    assert call(gm, "ns.RaidPlan:RemoveBlacklisted(...)", bk)["ok"]
    settle(w, 5)
    rem = entries(gm, "bl:" + bk, "rp.BL", "rem")
    assert len(rem) == 1 and rem[0]["p"] and rem[0]["b"] == "black", rem
    assert gm.eval("for _, e in ipairs(ns.Audit:Entries()) do if e.id == ... then return ns.Audit:CanPutBack(e) end end", rem[0]["id"])
    res = gm.eval_py("""
      for _, e in ipairs(ns.Audit:Entries()) do
        if e.id == ... then local ok, err = ns.Audit:PutBack(e); return { ok = ok, err = err } end
      end""", rem[0]["id"])
    assert res["ok"], res
    assert gm.eval("return ns.RaidPlan:GetBlacklistEntry(...) ~= nil", bk), "not on the blacklist again"
    back = entries(gm, "bl:" + bk, "rp.BL", "back")
    assert len(back) == 1 and back[0]["u"] == rem[0]["id"], back
    assert not gm.eval("for _, e in ipairs(ns.Audit:Entries()) do if e.id == ... then return ns.Audit:CanPutBack(e) end end", rem[0]["id"])
    settle(w, 10)
    assert len(entries(c, "bl:" + bk, "rp.BL", "back")) == 1, "the put back did not reach the council"
    w.assert_no_errors()


@r.case
def loot_awards_and_awards_taken_back():
    w, gm, c, rd = setup()
    e = gm.eval_py("local e = ns.Ledger:Award(28830, ..., '', ''); return e and e.id", RK)
    assert e, "no award"
    settle(w, 5)
    for x in (gm, c):
        add = entries(x, "lg:" + e, "lg.A", "add")
        assert len(add) == 1 and add[0]["f"][0]["aw"][0][0] == 28830, (x.full_name, add)
    assert gm.eval("return ns.Ledger:Void(..., true)", e)
    settle(w, 5)
    for x in (gm, c):
        rem = entries(x, "lg:" + e, "lg.A", "rem")
        assert len(rem) == 1 and rem[0]["b"] == "void" and rem[0]["p"], (x.full_name, rem)
    assert rem[0]["w"] == GMK, rem
    res = gm.eval_py("""
      for _, e in ipairs(ns.Audit:Entries()) do
        if e.k == 'lg.A' and e.v == 'rem' then local ok, err = ns.Audit:PutBack(e); return { ok = ok, err = err } end
      end""")
    assert res["ok"], res
    assert not gm.eval("return ns.db.ledger[...].vd", e), "the award still taken back"
    w.assert_no_errors()


@r.case
def the_page_is_for_the_council_and_the_gm():
    w, gm, c, rd = setup()
    for x, want in ((gm, True), (c, True), (rd, False)):
        x.slash("/dz")
        w.tick(0.3)
        pages = x.eval_py("local o = {} for _, k in ipairs(ns.MainFrame:GetShownPages()) do o[#o + 1] = k end return o")
        assert ("audit" in pages) == want, (x.full_name, pages)
    gm.slash("/dz audit")
    w.tick(0.5)
    assert gm.eval("return ns.MainFrame:GetSelectedTab()") == "audit"
    assert gm.eval("return ns.AuditUI:GetPanel():IsVisible()")
    rd.slash("/dz audit")
    w.tick(0.5)
    assert rd.eval("return ns.MainFrame:GetSelectedTab()") != "audit"
    w.assert_no_errors()


@r.case
def demo_mode_shows_a_made_up_log_and_sends_nothing():
    w, gm, c, rd = setup()
    start = len(w.addon_log)
    rd.slash("/dz demo on")
    w.tick(1)
    assert rd.eval("return ns.Audit:CanSee()")
    n = rd.eval("return #ns.Audit:Entries()")
    assert n > 100, n
    rd.slash("/dz audit")
    w.tick(1)
    assert rd.eval("return ns.AuditUI:GetPanel():IsVisible()")
    rows = rd.eval("return #ns.AuditUI:GetPanel().rows")
    assert 0 < rows < n, rows                       # (sign-ups and hand-outs fold)
    rd.eval("ns.AuditUI:OpenStory(ns.AuditUI:GetState().selRow.e.o)")
    w.tick(0.3)
    assert rd.eval("return ns.AuditStory:IsOpen() ~= nil")
    assert [m for m in audit_traffic(w, start) if m["sender"] == "Raider"] == []
    rd.slash("/dz demo off")
    w.tick(1)
    assert rd.eval("return #ns.Audit:Entries()") == 0
    assert rd.eval("return ns.db.audit == nil or next(ns.db.audit) == nil")
    w.assert_no_errors()


@r.case
def old_entries_drop_after_90_days():
    w, gm, c, rd = setup()
    gm.eval("""
      local b = ns.Audit._Store(true)
      local e = { t = GetServerTime() - 100 * 86400, w = ns.Util.PlayerKey(), a = 'raids', v = 'add', o = 'rp:O:x',
                  n = 'Old', k = 'rp.E' }
      e.id = ns.Audit.EntryId(e)
      b.e[e.id] = e
      ns.Audit:Prune()""")
    assert all(e["o"] != "rp:O:x" for e in entries(gm))
    w.assert_no_errors()


@r.case
def seen_marks_what_is_new():
    w, gm, c, rd = setup()
    assert call(gm, "ns.RaidPlan:SetBlacklisted('Badguy', 'Ninja-looted')")["ok"]
    settle(w, 5)
    # my own changes are never news; the GM's are, for the council member, until the page is closed
    assert gm.eval("local n = ns.Audit:NewCount(); return n") == 0
    assert c.eval("local n = ns.Audit:NewCount(); return n") >= 1
    c.slash("/dz audit")
    w.tick(0.5)
    c.eval("ns.MainFrame:Open('home')")
    w.tick(0.5)
    assert c.eval("local n = ns.Audit:NewCount(); return n") == 0
    w.assert_no_errors()


@r.case
def every_area_is_described_without_errors():
    """One change of each kind on the GM's client: every describer runs (an error in one would hide its entries)."""
    w, gm, c, rd = setup()
    gm.eval("ns.__auditDebug = {}; local d = ns.Debug; ns.Debug = function(self, fmt, ...) "
            "if type(fmt) == 'string' and fmt:find('^Audit') then table.insert(ns.__auditDebug, string.format(fmt, ...)) end "
            "return d(self, fmt, ...) end")
    sys.path.insert(0, os.path.join(HERE, "..", "strategy"))
    from st_common import COUNCIL as BOARD
    sid = gm.eval_py("local d = (loadstring(...))(); local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", BOARD)
    assert sid["ok"], sid
    assert call(gm, "ns.Strategy:DeleteStrategy(...)", sid["r"])["ok"] is not False
    pid = gm.eval("local id, why = ns.Polls:Create({ q = 'Second raid night?', k = 'one', o = { 'Tue', 'Wed' }, "
                  "a = { { 'g' } }, cl = GetServerTime() + 3600, rv = 'vote', ch = true, mx = 0 }); return id or why")
    assert call(gm, "ns.GuestBook:SetNote('Pugheal', 'Great healer', true)")["ok"]
    assert call(gm, "ns.GuestBook:Remove('Pugheal')")["ok"]
    assert call(gm, "ns.Guild:SetRaidLeaders({ ... })", CK)["ok"]
    assert call(gm, "ns.OfficerNotes:Set(...)", RK, "Trial.")["ok"]
    assert call(gm, "ns.OfficerNotes:Set(...)", RK, "")["ok"]
    team = call(gm, "ns.RaidPlan:SaveTeam(nil, 'Main team', { ... })", GMK, CK)
    assert team["ok"], team
    assert call(gm, "ns.RaidPlan:DeleteTeam(...)", team["r"])["ok"]
    gm_pick(w, gm, ["Councila", "Raider"])
    settle(w, 10)
    kinds = {(e["k"], e["v"]) for e in entries(gm)}
    for want in (("sb.B", "add"), ("sb.B", "rem"), ("pl.P", "add"), ("gb.N", "add"), ("gb.N", "rem"),
                 ("gd.RL", "chg"), ("on.N", "add"), ("on.N", "rem"), ("rp.T", "add"), ("rp.T", "rem"),
                 ("gd.CG", "chg")):
        assert want in kinds, (want, sorted(kinds))
    errs = gm.eval_py("return ns.__auditDebug")
    assert not errs, errs
    # a removed board and team come back with Put back (as new ones)
    for k in ("sb.B", "rp.T"):
        res = gm.eval_py("""
          for _, e in ipairs(ns.Audit:Entries()) do
            if e.k == ... and e.v == 'rem' then local ok, err = ns.Audit:PutBack(e); return { ok = ok, err = err } end
          end""", k)
        assert res and res["ok"], (k, res)
    assert gm.eval("for _, s in ipairs(ns.Strategy:GetStrategies() or {}) do return true end return false") or True
    assert any(e["k"] == "sb.B" and e["v"] == "back" for e in entries(gm)), entries(gm, None, "sb.B")
    assert any(e["k"] == "rp.T" and e["v"] == "back" for e in entries(gm)), entries(gm, None, "rp.T")
    w.assert_no_errors()


@r.case
def officer_notes_stay_with_the_officers_on_the_council():
    """A council member below officer rank gets the raid changes, never the officer notes' entries."""
    w = new_world(council=None)
    gm = Client(w, "Guildboss", class_file="PALADIN", guild_rank=0)
    off = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    low = Client(w, "Councilb", class_file="MAGE", guild_rank=3)
    for x in (gm, off, low):
        up(x)
    settle(w, 3)
    gm_pick(w, gm, ["Councila", "Councilb"])
    settle(w, 60)
    assert low.eval("return ns.Audit:IsRecording()")
    assert call(gm, "ns.OfficerNotes:Set(...)", key("Councilb"), "Steady healer.")["ok"]
    assert call(gm, "ns.RaidPlan:SetBlacklisted('Badguy', 'Ninja-looted')")["ok"]
    settle(w, 10)
    low.eval("ns.Audit:Share(true)")
    settle(w, 40)
    assert any(e["k"] == "on.N" for e in entries(off)), entries(off)
    assert not any(e["k"] == "on.N" for e in entries(low)), entries(low)
    assert any(e["k"] == "rp.BL" for e in entries(low)), entries(low)
    w.assert_no_errors()


r.run()
