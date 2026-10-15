"""Groups, step 1 (Core/DungeonRuns.lua + Data/GroupKinds.lua): runs of every kind besides 5-man dungeons.

Covers: a raid group reaches the guild with its places (10, 25, several raids in one); the wire of a dungeon run is
unchanged and a group of another kind has no d; a client on release 1.4.6's DungeonRuns keeps seeing dungeon runs and
ignores the rest (live and in a digest), and its profile reads as "up for dungeons"; PvP, quest and other groups and
what List refuses; accepting players past five turns the party into a raid and the group goes on in it; a raid lockout
blocks joining and listing and is shared; pings follow the kinds I'm up for; a digest leaves a big roster out and the
owner sends it on request; the lead of a raid group passes in the raid.

Run: luaenv\\Scripts\\python.exe tests\\groups\\test_groups_core.py [-k name]   (from dev)
"""
import atexit
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402
import harness  # noqa: E402

HELLO = 50
REPO = os.path.dirname(os.path.dirname(TESTS))
OLD_TAG = "release-1.4.6"
OLD_DIR = os.path.join(os.path.dirname(TESTS), "tf_e", "_groups_old_%d" % os.getpid(), "DisasterZone")


def old_addon():
    """This addon with Core/DungeonRuns.lua and UI/DungeonsTab.lua as release 1.4.6 shipped them (built once per run,
    removed at the end)."""
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
    # the core and its page as 1.4.6 shipped them (the new UI/GroupsCard.lua loads too, unused by the old page)
    for rel in ("Core/DungeonRuns.lua", "UI/DungeonsTab.lua"):
        data = subprocess.check_output(["git", "-C", REPO, "show", "%s:addon/DisasterZone/%s" % (OLD_TAG, rel)])
        with open(os.path.join(OLD_DIR, *rel.split("/")), "wb") as fh:
            fh.write(data)
    atexit.register(shutil.rmtree, os.path.dirname(OLD_DIR), True)
    return OLD_DIR


def guild(names, tick=HELLO, old=()):
    """names: [(name, class)] -> world, {name: client}, everyone logged in and past the hello. old: names on 1.4.6."""
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        kw = {"addon_dir": old_addon()} if name in old else {}
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3, **kw)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def K(cl):
    return cl.full_name


def roles(cl, *on):
    for r in on:
        cl.eval("ns.DungeonRuns:SetMyRole(...)", r, True)
    for r in ("tank", "healer", "dps"):
        if r not in on:
            cl.eval("ns.DungeonRuns:SetMyRole(...)", r, False)


def list_group(cl, **opts):
    """Lists a group from Lua options (k, a, n, w, lo, lr, pr, mr, fc, role, at, no): its id, or why not."""
    return cl.eval_py("""
      local o = ...
      local t = {}
      for k, v in pairs(o) do t[k] = v end
      local r, why = ns.DungeonRuns:List(t)
      return r and r.id or why""", opts)


def groups(cl, kind=None):
    return cl.eval_py("""
      local out = {}
      for _, r in ipairs(ns.DungeonRuns:GetGroups(...)) do
        local s = {}
        for _, x in ipairs(r.s or {}) do s[#s + 1] = x.k .. '=' .. x.r end
        local w = ns.DungeonRuns:GetWant(r)
        out[#out + 1] = { id = r.id, k = ns.DungeonRuns:GetKind(r), a = r.a, n = ns.DungeonRuns:GetSize(r),
                          w = { w.tank, w.healer, w.dps }, o = r.o, s = s, name = ns.DungeonRuns:GetName(r),
                          lo = r.lo, lr = r.lr, pr = r.pr or false, mr = r.mr, fc = r.fc or false, pt = r.pt or false }
      end
      table.sort(out, function(x, y) return x.id < y.id end)
      return out""", kind) or []


def dungeon_runs(cl):
    return cl.eval_py("local out = {}; for _, r in ipairs(ns.DungeonRuns:GetRuns()) do out[#out + 1] = r.id end; "
                      "return out") or []


def slot_counts(cl, rid):
    return cl.eval_py("""
      local n = { filled = 0, tank = 0, healer = 0, dps = 0 }
      local slots = ns.DungeonRuns:GetSlots(ns.DungeonRuns:GetGroup(...))
      for _, x in ipairs(slots) do
        if x.empty then n[x.role] = n[x.role] + 1 else n.filled = n.filled + 1 end
      end
      n.total = #slots
      return n""", rid)


def record_sent(cl):
    """From now on, every message cl's Comm sends is kept in __SENT (its type and keys)."""
    cl.eval("""
      __SENT = {}
      local Comm = ns.Comm
      local send = Comm.Send
      Comm.Send = function(self, msg, ...)
        if type(msg) == 'table' then
          local keys = {}
          for k in pairs(msg) do keys[#keys + 1] = tostring(k) end
          table.sort(keys)
          __SENT[#__SENT + 1] = { t = msg.t, keys = table.concat(keys, ','), msg = msg }
        end
        return send(self, msg, ...)
      end""")


def sent(cl, t):
    return cl.eval_py("""
      local out = {}
      for _, e in ipairs(__SENT or {}) do if e.t == ... then out[#out + 1] = e.keys end end
      return out""", t) or []


def pings(cl):
    cl.eval("if not __PINGS then __PINGS = {}; ns:On('DUNGEON_RUN_PING', function(id) __PINGS[#__PINGS + 1] = id end) end")


def pinged(cl):
    return cl.eval_py("local out = {}; for _, id in ipairs(__PINGS or {}) do out[#out + 1] = id end; return out") or []


SEVEN = [("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE"), ("Dora", "ROGUE"), ("Evie", "HUNTER"),
         ("Finn", "WARLOCK"), ("Hana", "PRIEST")]


# ------------------------------------------------------------------------------------------------------------------
@case
def a_raid_group_reaches_the_guild_with_its_places():
    w, c = guild(SEVEN[:4])
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer", no="alt run")
    assert ":" in rid, rid
    w.tick(3)
    for name in ("Bert", "Cara", "Dora"):
        gs = groups(c[name])
        assert len(gs) == 1 and gs[0]["id"] == rid, (name, gs)
        x = gs[0]
        assert x["k"] == "raid" and x["a"] == ["Karazhan"] and x["n"] == 10 and x["w"] == [2, 3, 5], x
        assert x["name"] == "Karazhan" and x["s"] == [K(g) + "=healer"] and x["lo"] == "roll", x
        # the dungeon pages see dungeon runs only
        assert dungeon_runs(c[name]) == [], name
        assert c[name].eval_py("return ns.DungeonRuns:GetRun(...) == nil", rid) is True
    assert slot_counts(cara, rid) == {"filled": 1, "tank": 2, "healer": 2, "dps": 5, "total": 10}
    roles(b, "tank")
    assert b.eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetGroup(...))", rid) == "tank"
    assert cara.eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetGroup(...))", rid) == "dps"
    # several raids in one night are one group, as big as the biggest; my places and loot method travel
    rid2 = list_group(g, k="raid", a=["GruulsLair", "MagtheridonsLair"], role="healer", lo="sr", lr=2,
                      w={"tank": 3, "healer": 7, "dps": 15})
    assert rid2 == rid, rid2      # (one group of mine at a time: the new listing replaces the old)
    w.tick(3)
    x = groups(cara)[0]
    assert x["n"] == 25 and x["w"] == [3, 7, 15] and x["lo"] == "sr" and x["lr"] == 2, x
    assert x["name"] == "Gruul's Lair + Magtheridon's Lair", x["name"]
    assert slot_counts(cara, rid) == {"filled": 1, "tank": 3, "healer": 6, "dps": 15, "total": 25}
    # back to a dungeon: the same id, a dungeon run again everywhere
    g.eval("ns.DungeonRuns:List({ d = 'Botanica', h = true, role = 'healer' })")
    w.tick(3)
    assert dungeon_runs(cara) == [rid] and groups(cara, "raid") == [], groups(cara)
    w.assert_no_errors()


@case
def the_wire_of_a_dungeon_run_is_unchanged_and_other_kinds_have_no_d():
    w, c = guild(SEVEN[:3])
    g = c["Gina"]
    record_sent(g)
    list_group(g, d="Botanica", h=True, role="healer")
    w.tick(3)
    drl = sent(g, "DRL")
    assert drl and all(k == "at,c,d,h,id,rv,s,t" for k in drl), drl
    record_sent(g)
    list_group(g, k="raid", a=["Karazhan"], role="healer", lo="sr")
    w.tick(3)
    drl = sent(g, "DRL")
    assert drl and all(",d," not in "," + k + "," and ",h," not in "," + k + "," for k in drl), drl
    assert all(k == "a,at,c,id,k,lo,lr,n,rv,s,t,w" for k in drl), drl
    # my profile tells the kinds I'm up for and the raids I'm saved to
    record_sent(g)
    g.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(3)
    drp = sent(g, "DRP")
    assert drp and all(",uk," in "," + k + "," and ",rs," in "," + k + "," for k in drp), drp
    w.assert_no_errors()


@case
def an_old_client_keeps_seeing_dungeon_runs_and_ignores_the_rest():
    w, c = guild(SEVEN[:4], old=("Dora",))
    g, b, d = c["Gina"], c["Bert"], c["Dora"]
    # (Dora runs release 1.4.6's DungeonRuns: no GetGroups)
    assert d.eval_py("return ns.DungeonRuns.GetGroups == nil") is True
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    did = list_group(b, d="ShatteredHalls", h=True, role="tank")
    w.tick(3)
    old_runs = d.eval_py("local out = {}; for _, r in ipairs(ns.DungeonRuns:GetRuns()) do out[#out + 1] = r.id end; "
                         "return out")
    assert old_runs == [did], old_runs
    assert d.eval_py("return ns.DungeonRuns:GetRun(...) == nil", rid) is True
    # a new client reads the old client's profile as "up for dungeons"
    d.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(3)
    assert g.eval_py("local p = ns.DungeonRuns:GetPeer(...); return p and p.kinds", K(d)) == {"dungeon": True}
    # and the old client's digest of the board after a login: the dungeon run, nothing else, no errors
    d.relog(reload=False)
    w.tick(HELLO + 10)
    old_runs = d.eval_py("local out = {}; for _, r in ipairs(ns.DungeonRuns:GetRuns()) do out[#out + 1] = r.id end; "
                         "return out")
    assert old_runs == [did], old_runs
    # a new client logging in while the old one is the one it asks still gets the raid from its owner
    assert [x["id"] for x in groups(c["Cara"])] == sorted([rid, did]), groups(c["Cara"])
    w.assert_no_errors()


@case
def pvp_quest_and_other_groups_and_what_list_refuses():
    w, c = guild(SEVEN[:3])
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    # rated: only with a team of that bracket; the group carries the team's name
    assert list_group(g, k="pvp", a=["arena3"], role="healer", pr=True) == "Rated games need your 3v3 team."
    g.eval("__MOCK.arena[1] = { name = 'Disastrous Decisions', size = 3, rating = 1712, members = { 'Gina' } }")
    rid = list_group(g, k="pvp", a=["arena3"], role="healer", pr=True, mr=1650)
    w.tick(3)
    x = groups(cara)[0]
    assert x["k"] == "pvp" and x["n"] == 3 and x["w"] == [0, 1, 2] and x["pr"] is True and x["mr"] == 1650, x
    assert cara.eval_py("return ns.DungeonRuns:GetGroup(...).tn", rid) == "Disastrous Decisions"
    assert x["name"] == "Arena 3v3", x
    # no tanks in PvP: a warrior up for tanking only doesn't fit, as DPS he does
    roles(b, "tank")
    assert b.eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetGroup(...))", rid) is None
    roles(b, "tank", "dps")
    assert b.eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetGroup(...))", rid) == "dps"
    # a battleground premade: its size, a healer share, flag carrier
    list_group(g, k="pvp", a=["av"], role="healer", fc=True)
    w.tick(3)
    x = groups(cara)[0]
    assert x["n"] == 40 and x["w"] == [0, 11, 29] and x["fc"] is True, x
    # a group quest (quest ids as they are) and "other"
    list_group(g, k="quest", a=[9977, 9982], role="healer", n=5)
    w.tick(3)
    x = groups(cara)[0]
    assert x["k"] == "quest" and x["a"] == [9977, 9982] and x["n"] == 5 and x["w"] == [1, 1, 3], x
    list_group(g, k="other", a=["attune"], role="healer", n=3, no="Arcatraz key")
    w.tick(3)
    x = groups(cara)[0]
    assert x["k"] == "other" and x["name"] == "Attunement" and x["n"] == 3 and x["w"] == [1, 1, 1], x
    # what List refuses
    assert list_group(g, k="pvp", a=["arena2", "arena3"]) == "Pick what the group is for."
    assert list_group(g, k="raid", a=["Naxxramas"]) == "Pick what the group is for."
    assert list_group(g, k="raid", a=["Karazhan"], w={"tank": 5, "healer": 5, "dps": 5}) == "More places than players."
    assert list_group(g, k="quest", a=[9977], n=41) == "A group is 2 to 40 players."
    assert list_group(g, k="dragons", a=["x"]) == "Pick what the group is for."
    # a group of 5 or fewer can't be listed from a raid
    g.eval("InviteUnit('Bert')")
    w.tick(2)
    g.eval("ConvertToRaid()")
    w.tick(2)
    assert list_group(g, k="pvp", a=["arena3"]) == "A raid can't list a group of 3."
    w.assert_no_errors()


@case
def accepting_players_past_five_makes_the_party_a_raid():
    w, c = guild(SEVEN)
    g = c["Gina"]
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    want = {"Bert": "tank", "Cara": "dps", "Dora": "dps", "Evie": "dps", "Finn": "dps", "Hana": "healer"}
    for name, role in want.items():
        roles(c[name], role)
        ok = c[name].eval_py("return ns.DungeonRuns:Join(...)", rid)
        assert ok is True, (name, ok)
    w.tick(2)
    for name in want:
        assert g.eval_py("return ns.DungeonRuns:Accept(...)", rid, K(c[name])) is True, name
        w.tick(3)
    w.tick(5)
    assert w.group and w.group["kind"] == "raid" and len(w.group["members"]) == 7, w.group and w.group["kind"]
    # the group goes on in the raid: listed, its places filled by who joined, as the roles they asked for
    x = groups(c["Cara"])[0]
    assert x["id"] == rid and len(x["s"]) == 7, x
    assert sorted(x["s"]) == sorted([K(g) + "=healer"] + [K(c[n]) + "=" + r for n, r in want.items()]), x["s"]
    assert slot_counts(c["Cara"], rid) == {"filled": 7, "tank": 1, "healer": 1, "dps": 1, "total": 10}
    w.assert_no_errors()


@case
def a_raid_lockout_blocks_joining_and_listing_and_is_shared():
    w, c = guild(SEVEN[:3])
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    # Bert is saved to Karazhan, 4 of 11 down
    b.eval("""__MOCK.saved = { { 'Karazhan', 123, 3 * 86400, 3, true, false, 0, true, 10, '10 Player', 11, 4, false,
                                 532 } }""")
    b.eval("ns.DungeonRuns:ScanSaved()")
    assert b.eval_py("local t, d, n = ns.DungeonRuns:GetRaidSaved('Karazhan'); return { t ~= nil, d, n }") == \
        [True, 4, 11]
    why = b.eval_py("return (ns.DungeonRuns:GetGroupBlocker(ns.DungeonRuns:GetGroup(...)))", rid)
    assert why == "You're saved to Karazhan (4 of 11)", why
    roles(b, "tank")
    ok, why = b.eval_py("return { ns.DungeonRuns:Join(...) }", rid)
    assert ok is False and why == "You're saved to Karazhan (4 of 11)", (ok, why)
    assert list_group(b, k="raid", a=["Karazhan"]) == "You're saved to Karazhan (4 of 11)"
    # saved to one of two raids: free to go
    assert ":" in list_group(b, k="raid", a=["Karazhan", "GruulsLair"], role="tank")
    # the guild knows (Bert's profile)
    w.tick(5)
    assert cara.eval_py("return ns.DungeonRuns:IsSavedToRaid(...)", K(b), "Karazhan") is True
    assert cara.eval_py("return ns.DungeonRuns:IsSavedToRaid(...)", K(b), "GruulsLair") is False
    w.assert_no_errors()


@case
def pings_follow_the_kinds_im_up_for():
    w, c = guild(SEVEN[:4])
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    roles(b, "tank")
    pings(b)
    assert b.eval_py("return ns.DungeonRuns:GetMyKinds()") == {"dungeon": True, "raid": True}
    b.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(3)
    q = list_group(cara, k="quest", a=[9977], role="dps", n=3)
    w.tick(3)
    assert pinged(b) == [], pinged(b)          # (not up for quests)
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    assert pinged(b) == [rid], pinged(b)
    # up for quests too: the quest group pings now
    assert b.eval_py("return ns.DungeonRuns:SetMyKind('quest', true)") is True
    w.tick(1)
    assert pinged(b) == [rid, q], pinged(b)
    # the guild sees what he's up for (his profile goes out 2 s after the change)
    w.tick(3)
    assert g.eval_py("local p = ns.DungeonRuns:GetPeer(...); return p and p.kinds", K(b)) == \
        {"dungeon": True, "raid": True, "quest": True}
    # at least one kind stays on
    for k in ("dungeon", "raid", "quest"):
        b.eval("ns.DungeonRuns:SetMyKind(...)", k, False)
    assert b.eval_py("return ns.DungeonRuns:GetMyKinds()") == {"quest": True}
    w.assert_no_errors()


@case
def a_digest_leaves_a_big_roster_out_and_the_owner_sends_it():
    w, c = guild(SEVEN[:4])
    g, d = c["Gina"], c["Dora"]
    rid = list_group(g, k="raid", a=["GruulsLair"], role="healer")
    # (Gina's group, as if 21 more had joined: names only she knows; the next roster change goes out)
    g.eval("""
      local run = ns.DungeonRuns:GetMyGroup()
      for i = 1, 21 do run.s[#run.s + 1] = { k = 'Pug' .. i .. '-Thunderstrike', r = 'dps', c = 'ROGUE' } end
      ns.DungeonRuns:SetPartyRole('Pug1-Thunderstrike', 'healer')""")
    w.tick(3)
    assert len(groups(c["Cara"])[0]["s"]) == 22
    # every digest is too big while it carries more than 19 places
    for cl in c.values():
        cl.eval("""
          local Comm = ns.Comm
          local fits = Comm.Fits
          Comm.Fits = function(self, msg)
            if type(msg) == 'table' and msg.t == 'DRS' then
              local n = 0
              for _, x in ipairs(msg.l or {}) do n = n + #x.s end
              return n * 200 <= 3800, n * 200, 0
            end
            return fits(self, msg)
          end""")
    # (Dora forgets the board she saved, so the digest is where she learns of the group)
    d.eval("""
      local b = ns.DB:GuildBucket('runs', false, ns.Guild:GetGuildKey())
      for id in pairs(b and b.list or {}) do b.list[id] = nil end""")
    d.relog(reload=False)
    record_sent(d)
    w.tick(HELLO + 10)
    assert sent(d, "DRR"), sent(d, "DRR")
    x = groups(d)[0]
    assert x["id"] == rid and len(x["s"]) == 22 and x["pt"] is False, (len(x["s"]), x["pt"])
    w.assert_no_errors()


@case
def the_lead_of_a_raid_group_passes_in_the_raid():
    w, c = guild(SEVEN[:3])
    g, b = c["Gina"], c["Bert"]
    g.eval("InviteUnit('Bert')")
    w.tick(2)
    g.eval("ConvertToRaid()")
    w.tick(2)
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    assert ":" in rid, rid
    w.tick(3)
    assert len(groups(c["Cara"])[0]["s"]) == 2
    g.eval("PromoteToLeader('Bert')")
    w.tick(15)
    mine = b.eval_py("local r = ns.DungeonRuns:GetMyGroup(); return r and { k = r.k, a = r.a, pv = r.pv }")
    assert mine == {"k": "raid", "a": ["Karazhan"], "pv": rid}, mine
    assert g.eval_py("return ns.DungeonRuns:GetMyGroup() == nil") is True
    xs = groups(c["Cara"])
    assert len(xs) == 1 and xs[0]["o"] == K(b) and xs[0]["k"] == "raid", xs
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())
