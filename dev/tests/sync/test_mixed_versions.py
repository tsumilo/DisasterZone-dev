"""Mixed versions (refactor 1.4, phase 5): a client on the 1.3.5 sync code and clients on the new one sync the digest
modules both ways (events, polls, prized items, strategies + assignments, raid plans) and the rev-list handshakes
(raid blacklist, guest book notes).

The old client is this addon with the sync files of release 1.3.5 put back (git show 0f0b272:<file> for every file
phase 5 changed: Core/Sync.lua, Events.lua, Polls.lua, Prized.lua, RaidPlan.lua, Strategy.lua, GuestBook.lua,
Ledger.lua, RaidLog.lua; Core/DigestSync.lua stays, unused by them). Cases:
  old_writes_new_catches_up      the old client writes everything; new clients take the live changes; a new client
                                 that was away catches up while only the old client is online (old XXD -> new)
  new_writes_old_catches_up      new clients write everything while the old client is away; it catches up while only
                                 new clients are online (new XXD -> old)
  live_both_ways                 both online: each answers the other's poll, signs up for the other's raid and edits
                                 the other's data where allowed; everyone ends the same
1.4.1 (an in-game update) against real 1.4.0 clients: every addon file that differs from release-1.4.0 put back (git
show release-1.4.0:<file>, Core/Guild.lua and Core/DigestSync.lua included), so the old client is 1.4.0 as shipped:
  raid_leaders_old_and_new       the raid leaders list (HELLO rlr, RLL, RLQ) both ways: an officer answers an older
                                 rev in a login HELLO, and an officer holding an older list asks (RLQ) the one whose
                                 HELLO shows a newer one; old -> new and new -> old
  raid_leaders_with_the_135_sync  the same under the 1.3.5 harness (old Sync.lua, new Guild.lua): rlr reaches Guild
                                 twice per HELLO, still one answer and one question
  the_hello_is_the_same_as_140s  a login HELLO decodes to the same table as 1.4.0's (rlr and av now registered fields)
  graves_against_an_old_client   a 1.4.0 member away 45 days comes back with a deleted event, poll and strategy: it
                                 gets the deletions back and ends without them; once it pruned, logins send no digest
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

from _common import World, Client, case, run_all, gm_pick, toc_version  # noqa: E402
import harness  # noqa: E402
from st_common import COUNCIL, K  # noqa: E402
import lr_common as lr  # noqa: E402

OLD_COMMIT = "0f0b272"          # release 1.3.5
# Core/DB.lua is not swapped back: since 1.3.5 it only gained DB:GuildBucket (additive), which non-sync Core files
# now call, so the old client keeps the current one (its sync behaviour is the same).
OLD_FILES = ["Core/Sync.lua", "Core/Events.lua", "Core/Polls.lua", "Core/Prized.lua",
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


OLD_140 = "release-1.4.0"
OLD_140_DIR = os.path.join(os.path.dirname(TESTS), "tf_e", "_mixed_old_%d" % os.getpid(), "v140", "DisasterZone")


def old_140_addon():
    """This addon as release 1.4.0 shipped it: every file under addon/DisasterZone that differs from the tag (the
    working tree included) put back. Built once per run."""
    if os.path.exists(os.path.join(OLD_140_DIR, "DisasterZone.toc")):
        return OLD_140_DIR
    src = harness.ADDON_DIR
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        for f in files:
            if f.lower().endswith((".lua", ".toc", ".xml")):
                dst = os.path.join(OLD_140_DIR, rel, f)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(root, f), dst)
    out = subprocess.check_output(["git", "-C", REPO, "diff", "--name-only", OLD_140, "--", "addon/DisasterZone"])
    for path in out.decode("utf-8").split():
        dst = os.path.join(OLD_140_DIR, path[len("addon/DisasterZone/"):])
        try:
            data = subprocess.check_output(["git", "-C", REPO, "show", "%s:%s" % (OLD_140, path)],
                                           stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            if os.path.exists(dst):
                os.remove(dst)           # (a file 1.4.0 didn't have)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(data)
    return OLD_140_DIR


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


def ledger(cl):
    return sorted(cl.eval_py("local out = {} for id in pairs(ns.db.ledger or {}) do out[#out + 1] = id end return out")
                  or [])


@case
def ledger_days_both_ways():
    """The award ledger's day digests (H ld, LW / LG) between the old and a new guild council member."""
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    gina.logout()
    w.tick(2)
    assert bob.eval_py("return ns.Ledger:Award(...)", 28477, K("Lee"), "", "council pick")
    w.tick(40)
    gina.login()
    w.tick(60)
    assert ledger(gina) == ledger(bob) and len(ledger(bob)) == 1, (ledger(gina), ledger(bob))
    bob.logout()
    w.tick(2)
    assert gina.eval_py("return ns.Ledger:Award(...)", 28453, K("Rita"), "", None)
    w.tick(40)
    bob.login()
    w.tick(60)
    assert ledger(gina) == ledger(bob) and len(ledger(bob)) == 2, (ledger(gina), ledger(bob))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# 1.4.1 against 1.4.0
# ------------------------------------------------------------------------------------------------------------------

def world_140(old=("Bob",)):
    """Gina = GM, Bob = officer + guild council, Lee / Rita / Sam / Uma = members. `old` run release 1.4.0."""
    w = World()
    c = {}
    for name, rank, cls in NAMES + (("Uma", 3, "HUNTER"),):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, addon_dir=old_140_addon() if name in old else None)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    w.tick(60)
    return w, c


def leaders(cl):
    return cl.eval_py("return ns.Guild:GetRaidLeaders()") or []


def set_leaders(cl, names):
    res = cl.eval_py("local ok, err = ns.Guild:SetRaidLeaders(...); return { ok = ok, err = err }", [K(n) for n in names])
    assert res.get("ok") is True, (cl.name, res)


def sent_to(w, t, mark, frm, to):
    """The whispers of type t from `frm` to `to` since that addon_log index."""
    dec = next(x for x in w.clients if x.runtime is not None and x.loaded)
    out = []
    for e in w.addon_log[mark:]:
        if (e["prefix"].startswith("CDL") and e["chat_type"] == "WHISPER" and e["sender"] == K(frm)
                and str(e["target"]).split("-")[0] == to):
            m = lr.decode_msg(dec, e["text"])
            if m and m.get("t") == t:
                out.append(m)
    return out


OLDER = "local g = ns.Guild:GetGuildKey(); local rec = ns.db.raidLeaders[g]; rec.rev = rec.rev - 100; rec.m = {}"


@case
def raid_leaders_old_and_new():
    w, c = world_140()
    bob, gina, sam = c["Bob"], c["Gina"], c["Sam"]
    # old officer -> new member who logs in later: Bob answers the older rlr in Sam's HELLO
    sam.logout()
    gina.logout()
    w.tick(2)
    set_leaders(bob, ["Rita"])
    w.tick(3)
    mark = len(w.addon_log)
    sam.login()
    w.tick(15)                     # (before anyone's share after logging in, 20-40 s)
    assert sent_to(w, "RLL", mark, "Bob", "Sam"), "the old officer's answer"
    assert leaders(sam) == [K("Rita")], leaders(sam)
    # new officer -> old officer who logs in later: Gina answers
    bob.logout()
    w.tick(2)
    gina.login()                   # (no officer online: she keeps her older list)
    w.tick(45)
    set_leaders(gina, ["Lee"])
    w.tick(3)
    mark = len(w.addon_log)
    bob.login()
    w.tick(15)
    assert sent_to(w, "RLL", mark, "Gina", "Bob"), "the new officer's answer"
    assert leaders(bob) == [K("Lee")], leaders(bob)
    w.tick(45)
    # a new officer holding an older list sees the old officer's HELLO: she asks him (RLQ), he answers
    gina.eval(OLDER)
    mark = len(w.addon_log)
    bob.relog(reload=False)
    w.tick(10)
    assert sent_to(w, "RLQ", mark, "Gina", "Bob"), "the new officer asks the old one"
    assert sent_to(w, "RLL", mark, "Bob", "Gina"), "the old officer answers"
    assert leaders(gina) == [K("Lee")], leaders(gina)
    w.tick(45)
    # and the other way round: the old officer asks the new one
    bob.eval(OLDER)
    mark = len(w.addon_log)
    gina.relog(reload=False)
    w.tick(10)
    assert sent_to(w, "RLQ", mark, "Bob", "Gina"), "the old officer asks the new one"
    assert sent_to(w, "RLL", mark, "Gina", "Bob"), "the new officer answers"
    assert leaders(bob) == [K("Lee")], leaders(bob)
    w.tick(45)
    for n, x in c.items():
        if x.online:
            assert leaders(x) == [K("Lee")], n
    w.assert_no_errors()


@case
def raid_leaders_with_the_135_sync():
    """The 1.3.5 harness keeps the new Core/Guild.lua under the old Core/Sync.lua: that Sync.lua passes rlr and av to
    Guild by hand and Guild registers them as HELLO fields too, so each HELLO reaches the handlers twice. The second
    call is rate-limited: one answer, one question."""
    w, c = world()
    bob, gina, sam = c["Bob"], c["Gina"], c["Sam"]
    sam.logout()
    gina.logout()
    w.tick(2)
    set_leaders(bob, ["Rita"])
    w.tick(3)
    mark = len(w.addon_log)
    sam.login()
    w.tick(15)
    assert len(sent_to(w, "RLL", mark, "Bob", "Sam")) == 1, sent_to(w, "RLL", mark, "Bob", "Sam")
    assert leaders(sam) == [K("Rita")], leaders(sam)
    gina.login()
    w.tick(45)
    bob.eval(OLDER)
    mark = len(w.addon_log)
    gina.relog(reload=False)
    w.tick(10)
    assert len(sent_to(w, "RLQ", mark, "Bob", "Gina")) == 1, sent_to(w, "RLQ", mark, "Bob", "Gina")
    assert leaders(bob) == [K("Rita")], leaders(bob)
    w.assert_no_errors()


def hello_of(gina_old):
    """Gina's login HELLO, decoded, in a guild with a raid leaders list, accounts, a raid, an event, a poll, a prized
    item and a strategy; Gina runs 1.4.0 when gina_old."""
    w, c = world_140(old=("Gina",) if gina_old else ())
    gina = c["Gina"]
    set_leaders(c["Bob"], ["Rita"])
    write_all(c["Bob"], "x", ["Lee", "Gina"])
    w.tick(60)
    mark = len(w.addon_log)
    gina.relog(reload=False)
    w.tick(30)
    hs = [m for m in lr.msgs_of_type(w, "H", mark, whole=True) if m["_sender"] == K("Gina")]
    assert len(hs) == 1, hs
    m = hs[0]
    for k in ("_sender", "_chat_type", "_time"):
        m.pop(k)
    own = gina.eval_py("return { pd = ns.RaidPlan:GetDigestHash(), sd = ns.Strategy:GetDigestHash(),"
                       " ed = ns.Events:GetDigestHash(), od = ns.Polls:GetDigestHash(), zd = ns.Prized:GetDigestHash(),"
                       " rlr = ns.Guild:GetRaidLeadersRev(), av = ns.Guild:GetAccountsHash() }")
    return m, own


DIGEST_FIELDS = ("pd", "sd", "ed", "od", "zd")


@case
def the_hello_is_the_same_as_140s():
    """rlr and av moved from Sync.lua into registered HELLO fields: the HELLO Gina sends is the one 1.4.0 sent (the
    same keys and values; n, the session nonce, aside)."""
    (old, old_own), (new, new_own) = hello_of(True), hello_of(False)
    # (1.4.2 adds dcr, the Discord links' rev: Core/Bridge.lua)
    assert set(old) == set(new) - {"dcr"}, (sorted(old), sorted(new))
    assert {"rlr", "av", "pd", "blr", "gnr", "sd", "ed", "od", "zd"} <= set(new), sorted(new)
    # (the digest hashes are over records with ids made from each world's clock: each is its own client's hash)
    for m, own in ((old, old_own), (new, new_own)):
        for f, v in own.items():
            assert m[f] == v, (f, m[f], v)
    assert old["v"] == "1.4.0" and new["v"] == toc_version(), (old["v"], new["v"])
    for m in (old, new):
        m.pop("n")
        m.pop("v")                                  # (each client says its own version)
        for f in DIGEST_FIELDS:
            m.pop(f)
    assert old == new, (old, new)
    assert new["rlr"] > 0, new


GRAVE_IDS = """
    local members, council = ...
    local out = {}
    local d = ns.Events:NewDef(true); d.name = 'Gone cup'
    out.def = ns.Events:SaveDef(d) and d.id or false
    local keep = ns.Events:NewDef(true); keep.name = 'Kept cup'
    out.keep = ns.Events:SaveDef(keep) and keep.id or false
    local targets = {}
    for i, k in ipairs(members) do targets[i] = { 'p', k } end
    out.poll = ns.Polls:Create({ q = 'Night?', k = 'one', o = { 'Wed', 'Thu' }, a = targets,
                                 cl = GetServerTime() + 60 * 86400 - 60, rv = 'live', ch = true, mx = 0 }) or false
    local s = (loadstring(council))(); s.n = 'Gone plan'
    local ok, sid = ns.Strategy:SaveStrategy(s)
    out.strat = ok and sid or false
    return out"""

GRAVE_HOLDS = """
    local ids = ...
    local g = ns.Guild:GetGuildKey()
    local function get(bucket, kind, id)
        local b = ns.db[bucket] and ns.db[bucket][g]
        local r = b and b[kind] and b[kind][id]
        if not r then return 'none' end
        return r.del and 'del' or 'live'
    end
    return { D = get('events', 'D', ids.def), P = get('polls', 'P', ids.poll), B = get('strategy', 'B', ids.strat) }"""

PRUNE = "ns.Events:Prune(); ns.Polls:Prune(); ns.Prized:Prune(); ns.Strategy:Prune()"
GONE = {"D": "del", "P": "del", "B": "del"}


def digest_hashes(cl):
    return cl.eval_py("return { ev = ns.Events:GetDigestHash(), po = ns.Polls:GetDigestHash(),"
                      " pz = ns.Prized:GetDigestHash(), sb = ns.Strategy:GetDigestHash() }")


@case
def graves_against_an_old_client():
    w, c = world_140(old=("Uma",))
    gina, uma, lee = c["Gina"], c["Uma"], c["Lee"]
    ids = gina.eval_py(GRAVE_IDS, [K("Uma"), K("Lee")], COUNCIL)
    assert all(v not in (False, None) for v in ids.values()), ids
    w.tick(10)
    assert uma.eval_py(GRAVE_HOLDS, ids) == {"D": "live", "P": "live", "B": "live"}
    uma.logout()
    w.tick(2)
    res = gina.eval_py("local ids = ...; return { ns.Events:DeleteDef(ids.def) and true or false,"
                       " ns.Polls:Delete(ids.poll) and true or false,"
                       " (ns.Strategy:DeleteStrategy(ids.strat)) and true or false }", ids)
    assert res == [True, True, True], res
    w.tick(5)
    w.server_time0 += 45 * DAY
    for x in c.values():
        if x.online:
            x.eval(PRUNE)
    uma.login()                    # 1.4.0, still holding the three
    w.tick(90)
    for n, x in c.items():
        held = x.eval_py(GRAVE_HOLDS, ids)
        if n == "Uma":     # the deletions came back to her; her prune 20-40 s after logging in may have dropped them
            assert set(held.values()) <= {"del", "none"}, held
        else:
            assert held == GONE, (n, held)
        assert x.eval("return ns.Events:GetDef(...) == nil", ids["def"]) is True, n
    # her daily prune drops the deletions (1.4.0: 30 days after them); then every hash is the same
    uma.eval(PRUNE)
    assert uma.eval_py(GRAVE_HOLDS, ids) == {"D": "none", "P": "none", "B": "none"}
    hs = {n: digest_hashes(x) for n, x in c.items() if x.online}
    assert len({tuple(sorted(h.items())) for h in hs.values()}) == 1, hs
    # steady state: logins (new and old) are answered with no digest
    for who in ("Lee", "Uma"):
        mark = len(w.addon_log)
        c[who].relog(reload=False)
        w.tick(60)
        got = digests_to(w, K(who), mark)
        assert not any(t in got for t in ("EVD", "PLD", "PZD", "SBD")), (who, got)
    # the deletions are still graves on the new clients: Uma never brings the copies back
    assert lee.eval_py(GRAVE_HOLDS, ids) == GONE
    assert uma.eval_py(GRAVE_HOLDS, ids) == {"D": "none", "P": "none", "B": "none"}
    w.assert_no_errors()


if __name__ == "__main__":
    try:
        run_all()
    finally:
        cleanup()
