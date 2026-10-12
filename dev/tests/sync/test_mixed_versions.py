"""Mixed versions (refactor 1.4, phase 5): a client on the 1.3.5 sync code and clients on the new one sync the digest
modules both ways (events, polls, prized items, strategies + assignments, raid plans) and the rev-list handshakes
(raid blacklist, guest book notes).

The old client is this addon with the sync files of release 1.3.5 put back (git show 0f0b272:<file> for every file
phase 5 changed: Core/Sync.lua, DB.lua, Events.lua, Polls.lua, Prized.lua, RaidPlan.lua, Strategy.lua, GuestBook.lua,
Ledger.lua, RaidLog.lua; Core/DigestSync.lua stays, unused by them). Cases:
  old_writes_new_catches_up      the old client writes everything; new clients take the live changes; a new client
                                 that was away catches up while only the old client is online (old XXD -> new)
  new_writes_old_catches_up      new clients write everything while the old client is away; it catches up while only
                                 new clients are online (new XXD -> old)
  live_both_ways                 both online: each answers the other's poll, signs up for the other's raid and edits
                                 the other's data where allowed; everyone ends the same
Run: luaenv\\Scripts\\python.exe tests\\sync\\test_mixed_versions.py [-k name]   (from dev)"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "strategy"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import World, Client, case, run_all, gm_pick  # noqa: E402
import harness  # noqa: E402
from st_common import COUNCIL, K  # noqa: E402
import lr_common as lr  # noqa: E402

OLD_COMMIT = "0f0b272"          # release 1.3.5
OLD_FILES = ["Core/Sync.lua", "Core/DB.lua", "Core/Events.lua", "Core/Polls.lua", "Core/Prized.lua",
             "Core/RaidPlan.lua", "Core/Strategy.lua", "Core/GuestBook.lua", "Core/Ledger.lua", "Core/RaidLog.lua"]
REPO = os.path.dirname(os.path.dirname(TESTS))
OLD_DIR = os.path.join(os.path.dirname(TESTS), "tf_e", "_mixed_old_%d" % os.getpid(), "DisasterZone")
DAY = 86400
ITEM = 28830                     # Dragonspine Trophy


def old_addon():
    """This addon with the 1.3.5 sync files (built once per run, removed at the end)."""
    if os.path.exists(os.path.join(OLD_DIR, "DisasterZone.toc")):
        return OLD_DIR
    src = harness.ADDON_DIR
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        for f in files:
            if f.lower().endswith((".lua", ".toc", ".xml")):
                dst = os.path.join(OLD_DIR, rel, f)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(root, f), dst)
    for rel in OLD_FILES:
        data = subprocess.check_output(["git", "-C", REPO, "show", "%s:addon/DisasterZone/%s" % (OLD_COMMIT, rel)])
        with open(os.path.join(OLD_DIR, rel), "wb") as fh:
            fh.write(data)
    return OLD_DIR


def cleanup():
    shutil.rmtree(os.path.dirname(OLD_DIR), ignore_errors=True)


NAMES = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))


def world(old=("Bob",)):
    """Gina = GM, Bob = officer + guild council + raid leader; Lee, Rita, Sam = members. `old` run the 1.3.5 files."""
    w = World()
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, addon_dir=old_addon() if name in old else None)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    res = c["Gina"].eval_py("local ok, err = ns.Guild:SetRaidLeaders(...); return { ok = ok, err = err }", [K("Bob")])
    assert res.get("ok") is True, res
    w.tick(60)     # every login HELLO and its answers are over
    return w, c


def write_all(cl, tag, members):
    """cl writes one of everything: an event (library + calendar), a poll asking `members`, a prized item (when
    allowed), a strategy, a raid with a fill (when allowed), a blacklist entry and a guest book note (when allowed)."""
    return cl.eval_py("""
        local tag, members, item, council = ...
        local out = {}
        local d = ns.Events:NewDef(true); d.name = 'Cup ' .. tag
        out.def = ns.Events:SaveDef(d) and d.id or false
        out.occ = out.def and ns.Events:Schedule(d.id, GetServerTime() + 3 * 86400) or false
        local targets = {}
        for i, k in ipairs(members) do targets[i] = { 'p', k } end
        out.poll = ns.Polls:Create({ q = 'Night? ' .. tag, k = 'one', o = { 'Wed', 'Thu' }, a = targets,
                                     cl = GetServerTime() + 3600, rv = 'live', ch = true, mx = 0 }) or false
        if ns.Prized:CanEdit() then
            local rec = ns.Prized:Add({ item }, { main = { m = 'r' } })
            out.prized = rec and rec.id or false
        end
        local s = (loadstring(council))(); s.n = 'Plan ' .. tag
        local ok, sid = ns.Strategy:SaveStrategy(s)
        out.strat = ok and sid or false
        local okR, occ = ns.RaidPlan:CreateRaid({ i = 'bt', t = GetServerTime() + 2 * 86400 })
        out.raid = okR and occ or false
        if okR and ok then
            local okF = ns.Strategy:SaveFill(occ, 'BlackTemple:Council', sid, { ['tk.1.1'] = members[1] })
            out.fill = okF and true or false
        end
        if ns.RaidPlan.CanManageRoster and ns.RaidPlan:CanManageRoster() then
            out.bl = (ns.RaidPlan:SetBlacklisted('Bad' .. tag, 'ninja ' .. tag)) and true or false
            out.note = (ns.GuestBook:SetNote('Pug' .. tag, 'healer ' .. tag, true)) and true or false
        end
        return out""", tag, [K(m) for m in members], ITEM, COUNCIL)


STATE = """
    local function h(m) return m and m.GetDigestHash and m:GetDigestHash() or '?' end
    return { ev = h(ns.Events), po = h(ns.Polls), pz = h(ns.Prized), sb = h(ns.Strategy), rp = h(ns.RaidPlan),
             blr = ns.RaidPlan:GetBlacklistRev(), gnr = ns.GuestBook:GetNotesRev(),
             bl = #(ns.RaidPlan:GetBlacklist() or {}) }"""


def state(cl):
    return cl.eval_py(STATE)


DIGESTS = ("EVD", "PLD", "PZD", "SBD", "RPD")


def digests_to(w, key, mark):
    """{ type: set of senders } of the digests sent to that key since that addon_log index."""
    out = {}
    for t in DIGESTS:
        for m in lr.msgs_of_type(w, t, mark, whole=True):
            if m.get("to") == key:
                out.setdefault(t, set()).add(m["_sender"])
    return out


def same(a, b, what, lists=True):
    sa, sb = state(a), state(b)
    if not lists:      # (the blacklist and the notes come from a roster manager only)
        for k in ("blr", "gnr", "bl"):
            sa.pop(k), sb.pop(k)
    assert sa == sb, "%s: %s %s vs %s %s" % (what, a.name, sa, b.name, sb)
    for k in ("ev", "po", "sb", "rp"):
        assert sa[k] != "0", "%s: %s holds no %s data" % (what, a.name, k)
    return sa


@case
def old_writes_new_catches_up():
    w, c = world()
    bob, sam = c["Bob"], c["Sam"]
    sam.logout()
    w.tick(2)
    out = write_all(bob, "o", ["Lee", "Rita", "Sam"])
    assert all(v not in (False, None) for v in out.values()), out
    assert {"prized", "fill", "bl", "note"} <= set(out), out
    w.tick(45)
    for n in ("Gina", "Lee", "Rita"):
        same(bob, c[n], "live changes from the old client")
    # only the old client online: it answers the new client's HELLO with its digests (and the revs)
    for n in ("Gina", "Lee", "Rita"):
        c[n].logout()
    w.tick(30)
    mark = len(w.addon_log)
    sam.login()
    w.tick(120)
    st = same(bob, sam, "new client caught up from the old one")
    got = digests_to(w, K("Sam"), mark)
    assert got == {t: {K("Bob")} for t in DIGESTS}, got
    assert st["pz"] != "0", st
    w.assert_no_errors()


@case
def new_writes_old_catches_up():
    w, c = world()
    bob, gina, lee = c["Bob"], c["Gina"], c["Lee"]
    bob.logout()
    w.tick(2)
    out = write_all(gina, "n", ["Lee", "Rita", "Bob"])
    assert all(v not in (False, None) for v in out.values()), out
    assert {"prized", "bl", "note"} <= set(out), out
    out2 = write_all(lee, "m", ["Rita"])          # a member: an event and a strategy (no poll, no raid rights)
    assert out2["def"] and out2["strat"], out2
    w.tick(45)
    same(gina, c["Rita"], "live changes between new clients")
    # only new clients online, none of them a roster manager
    for n in ("Gina", "Lee", "Sam"):
        c[n].logout()
    w.tick(30)
    mark = len(w.addon_log)
    bob.login()
    w.tick(120)
    got = digests_to(w, K("Bob"), mark)
    assert got == {t: {K("Rita")} for t in DIGESTS}, got
    same(bob, c["Rita"], "old client caught up from a new one", lists=False)
    # the blacklist and the notes: from a roster manager (the new GM), asked for by the old client (BLQ / GNQ)
    gina.login()
    w.tick(60)
    st = same(bob, gina, "old client took the lists from a new manager")
    assert st["blr"] > 0 and st["gnr"] > 0 and st["bl"] == 1, st
    w.assert_no_errors()


@case
def live_both_ways():
    w, c = world()
    bob, gina, rita = c["Bob"], c["Gina"], c["Rita"]
    o = write_all(bob, "o", ["Gina", "Rita"])
    n = write_all(gina, "n", ["Bob", "Rita"])
    w.tick(45)
    # each answers the other's poll, Rita (new) answers both
    assert bob.eval_py("return { ns.Polls:Vote(...) }", n["poll"], [1])[0] is True
    assert gina.eval_py("return { ns.Polls:Vote(...) }", o["poll"], [2])[0] is True
    assert rita.eval_py("return { ns.Polls:Vote(...) }", o["poll"], [1])[0] is True
    assert rita.eval_py("return { ns.Polls:Vote(...) }", n["poll"], [2])[0] is True
    # sign-ups for the other version's raid and event
    for cl, occ in ((rita, o["raid"]), (bob, n["raid"]), (gina, o["raid"])):
        res = cl.eval_py("local ok, e = ns.RaidPlan:SignUp(...); return { ok = ok, e = e }", occ, "A")
        assert res["ok"] is True, (cl.name, res)
    for cl, occ in ((rita, o["occ"]), (bob, n["occ"])):
        assert cl.eval("return ns.Events:SignUp(...)", occ, True), cl.name
    # the old raid leader fills the new raid; the new GM removes the old blacklist entry; the old officer edits the
    # GM's guest book note
    assert bob.eval_py("local ok = ns.Strategy:SaveFill(...); return { ok = ok }", n["raid"], "BlackTemple:Council",
                       o["strat"], {"tk.1.1": K("Rita")})["ok"] is True
    assert gina.eval_py("local ok = ns.RaidPlan:RemoveBlacklisted(...); return { ok = ok }", K("Bado"))["ok"] is True
    assert bob.eval_py("local ok = ns.GuestBook:SetNote('Pugn', 'tank now'); return { ok = ok }")["ok"] is True
    w.tick(45)
    st = same(bob, gina, "live, both ways")
    same(gina, rita, "live, both ways")
    same(bob, c["Lee"], "live, both ways")
    assert st["bl"] == 1, st
    res = rita.eval_py("local p = ns.Polls:GetPoll(...); local r = ns.Polls:Results(p); return r.counts", o["poll"])
    assert res == [1, 1], res      # Rita: Wed, Gina: Thu
    w.assert_no_errors()


if __name__ == "__main__":
    try:
        run_all()
    finally:
        cleanup()
