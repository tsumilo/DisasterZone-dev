"""Raids > Teams, the target comp (1.3.1 core: data, sync, logic; no UI), on the real addon.

Covers: a team's comp (cp on the team record) saved, read and cleared, only by the Guild Master and the guild council
(a member's write refused, a member's own record hidden); the comp reaching every client and a late login; an older
client's copy without the comp at the same rev never replacing it (and a client holding such a copy taking the full
one), digests agreeing after; the bundled presets (Standard 25, Kara 10) as agreed; "the team as it is" (seated
first, by name, capped at the size) and copying another team's comp ("Start from" choices, for a draft too); matching
members to slots by spec only (seated first, then by name; bench by column, unknown spec last; Destruction does not
fill Affliction, Cat does not fill Bear) the same whatever the input order; the can-fill lists in the agreed order
(bench, alts, the rest of the guild, other teams), with players of the class in another spec in the first two only,
each player once, sorted spec / online / name, and the spec index rebuilt after a change; a raid's open slots
(Accepted and Tentative fill, guests too, Bench and Absent don't, a member who hasn't answered leaves the slot open,
the first team with a comp of the raid's size, none for a cancelled raid) and who could fill them; the raid-buff
strip's three states; the LF line (exact text, x2, no raid, at most 255 bytes); hostile comps refused whole.

Run: luaenv\\Scripts\\python.exe tests\\teamcomp\\test_teamcomp.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, create, signup, call  # noqa: E402
from _common import case, run_all  # noqa: E402

# Gina = GM, Bob = guild council + raid leader; the others are members.
NAMES = (("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))

STD25 = {"WARRIOR": [0, 1, 1], "PALADIN": [2, 1, 1], "HUNTER": [0, 1, 1], "ROGUE": [0, 2], "PRIEST": [0, 1, 1],
         "SHAMAN": [1, 2, 2], "MAGE": [1, 1], "WARLOCK": [1, 0, 1], "DRUID": [1, 1, 1, 1]}
KARA10 = {"WARRIOR": [0, 0, 1], "PALADIN": [1, 1], "HUNTER": [0, 1], "ROGUE": [0, 1], "PRIEST": [0, 1],
          "SHAMAN": [0, 1], "MAGE": [0, 1], "WARLOCK": [0, 0, 1], "DRUID": [0, 0, 0, 1]}
STD25_SLOTS = [
    "Protection Warrior", "Protection Paladin", "Feral Druid (Bear)",
    "Holy Paladin", "Holy Paladin", "Holy Priest", "Restoration Shaman", "Restoration Shaman", "Restoration Druid",
    "Fury Warrior", "Retribution Paladin", "Combat Rogue", "Combat Rogue", "Enhancement Shaman", "Enhancement Shaman",
    "Feral Druid (Cat)",
    "Marksmanship Hunter", "Survival Hunter", "Shadow Priest", "Elemental Shaman", "Arcane Mage", "Fire Mage",
    "Affliction Warlock", "Destruction Warlock", "Balance Druid",
]
KARA10_SLOTS = ["Protection Warrior", "Protection Paladin", "Holy Paladin", "Holy Priest", "Restoration Druid",
                "Combat Rogue", "Enhancement Shaman", "Marksmanship Hunter", "Fire Mage", "Destruction Warlock"]
ROOT = "ns.db.raidplan[ns.Guild:GetGuildKey()]"


def world(names=NAMES, offline=(), pairs=()):
    """offline: (name, class, level) guild members without a client. pairs: (main, alt) characters of one account."""
    w = World()
    for n, cls, level in offline:
        w.add_offline_member(n, cls, 3, level)
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    for main, alt in pairs:
        own(c[main], alt)
        own(c[alt], main)
    w.tick(50 if pairs else 2)      # everyone's own account entry goes out 25-45 s after login
    return w, c


def own(cl, *alts):
    """As if those characters had logged in on cl's account (the saved variables are per account)."""
    cl.eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
            "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; "
            "for _, k in ipairs({...}) do ns.db.accounts[gk].mine[k] = true end", *[K(a) for a in alts])


def save(cl, name, members, tid=None, **opts):
    """SaveTeam; opts: size, specs {name: sp}, groups {name: g}, comp (dict, or False to clear)."""
    o = {}
    if "size" in opts:
        o["size"] = opts["size"]
    if "specs" in opts:
        o["specs"] = {K(n): sp for n, sp in opts["specs"].items()}
    if "groups" in opts:
        o["groups"] = {K(n): g for n, g in opts["groups"].items()}
    if "comp" in opts:
        o["comp"] = opts["comp"]
    return cl.eval_py("local id, n, m, o = ...; local ok, r = ns.RaidPlan:SaveTeam(id, n, m, o); return { ok = ok, r = r }",
                      tid, name, [K(m) for m in members], o)


def team(cl, *args, **opts):
    res = save(cl, *args, **opts)
    assert res["ok"] is True, res
    return res["r"]


def get_team(cl, tid):
    return cl.eval_py("return ns.RaidPlan:GetTeam(...)", tid)


def comp_of(cl, tid):
    t = get_team(cl, tid)
    return None if t is None else t.get("comp")


def rp(cl, fn, *args):
    """ns.RaidPlan:<fn>(...) -> its first value, as Python."""
    return cl.eval_py("local fn = ...; return (ns.RaidPlan[fn](ns.RaidPlan, select(2, ...)))", fn, *args)


def rc(cl, fn, *args):
    """ns.RaidComp:<fn>(...) -> its first value, as Python."""
    return cl.eval_py("local fn = ...; return (ns.RaidComp[fn](ns.RaidComp, select(2, ...)))", fn, *args)


def names(slots):
    return [s["name"] for s in slots]


def keys(entries):
    return [e["key"] for e in entries]


def inject_signups(cl, occ, entries):
    """Answers as if received earlier (offline members can't answer themselves): {name: (st, class, sp|None)}."""
    for n, (st, cls, sp) in entries.items():
        cl.eval("local o, k, st, c, sp = ...; local r = %s; r.U[o] = r.U[o] or {}; "
                "r.U[o][k] = { st = st, rev = GetServerTime(), c = c, sp = sp }" % ROOT, occ, K(n), st, cls, sp)
    cl.eval("ns:Fire('RAIDPLAN_CHANGED')")


def same_rev_copy_without_comp(cl, tid):
    return cl.eval_py("local id = ...; local t = %s.T[id]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; "
                      "copy.cp = nil; return copy" % ROOT, tid)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_council_saves_reads_and_clears_a_comp():
    w, c = world()
    gina, bob, lee, rita = c["Gina"], c["Bob"], c["Lee"], c["Rita"]
    tid = team(bob, "Main", ["Lee", "Rita"], comp=STD25)
    w.tick(2)
    for n, x in c.items():
        assert comp_of(x, tid) == STD25, n
        assert rp(x, "GetTeamComp", tid) == STD25, n
    # a rename keeps the comp (comp = nil keeps it); GetTeam hands out copies
    team(bob, "Main team", ["Lee", "Rita", "Sam"], tid)
    w.tick(2)
    assert comp_of(rita, tid) == STD25
    assert rita.eval("local t = ns.RaidPlan:GetTeam(...); t.comp.PALADIN[1] = 9; "
                     "return ns.RaidPlan:GetTeam(...).comp.PALADIN[1]", tid) == 2
    # the GM sets only the comp (non-canonical input is stored canonical); then clears it
    res = call(gina, "SetTeamComp", tid, {"PALADIN": [2, 0, 0], "MAGE": [0, 0, 0], "DRUID": [0, 0, 1]})
    assert res["ok"] is True, res
    w.tick(2)
    for n, x in c.items():
        assert comp_of(x, tid) == {"PALADIN": [2], "DRUID": [0, 0, 1]}, n
        assert get_team(x, tid)["name"] == "Main team" and len(get_team(x, tid)["members"]) == 3, n
    assert call(gina, "SetTeamComp", tid, False)["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert comp_of(x, tid) is None, n
        assert x.eval("return %s.T[...].cp" % ROOT, tid) is None, n
    # a draft whose slots were all taken out clears it too
    assert call(gina, "SetTeamComp", tid, KARA10)["ok"] is True
    w.tick(2)
    assert comp_of(bob, tid) == KARA10
    assert team(bob, "Main team", ["Lee", "Rita", "Sam"], tid, comp={}) == tid
    w.tick(2)
    for n, x in c.items():
        assert comp_of(x, tid) is None, n
    # members can't write it, whatever the way
    res = call(rita, "SetTeamComp", tid, KARA10)
    assert res["ok"] is False and "guild council" in res["e"], res
    res = save(lee, "Main team", ["Lee"], tid, comp=KARA10)
    assert res["ok"] is False, res
    assert comp_of(bob, tid) is None
    # a member's own team record with a comp, sent by hand: stored, never shown
    rita.eval("ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = 'rt1', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
              "n = 'Mine', m = { ns.Util.PlayerKey() }, cp = { PRIEST = { 0, 1 } } } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert lee.eval("return %s.T.rt1 ~= nil" % ROOT) is True
    assert get_team(lee, "rt1") is None
    # more slots than the team's size: refused, with a reason; the comp must fit before the size goes down
    res = save(bob, "Main team", ["Lee"], tid, size=10, comp=STD25)
    assert res["ok"] is False and "more than the team's 10" in res["r"], res
    assert team(bob, "Main team", ["Lee"], tid, comp=STD25) == tid
    res = save(bob, "Main team", ["Lee"], tid, size=10)
    assert res["ok"] is False and "25 slots" in res["r"], res
    assert team(bob, "Main team", ["Lee"], tid, size=10, comp=KARA10) == tid
    res = call(bob, "SetTeamComp", tid, STD25)
    assert res["ok"] is False and "more than the team's 10" in res["e"], res
    res = call(bob, "SetTeamComp", "nope", KARA10)
    assert res["ok"] is False and res["e"] == "unknown team", res
    w.tick(2)
    assert comp_of(rita, tid) == KARA10 and get_team(rita, tid)["size"] == 10
    w.assert_no_errors()


@case
def an_older_clients_copy_without_the_comp_never_wins():
    w, c = world()
    bob, lee, rita, sam = c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    # a version whose copy without cp has the larger hash: the plain same-rev rule (larger hash wins) would take it.
    # (The hash is Adler-32: the comp's own counts move it most, so they are what is varied.)
    tid, h, cp0 = None, None, None
    for i in range(80):
        cp0 = {"MAGE": [1 + i % 9, i // 9 % 9], "PRIEST": [0, 1 + i // 81]}
        tid = team(bob, "Main", ["Lee", "Rita"], tid, comp=cp0)
        h = bob.eval_py("local id = ...; local t = %s.T[id]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; "
                        "copy.cp = nil; return { full = ns.Util.Hash(t), without = ns.Util.Hash(copy) }" % ROOT, tid)
        if h["without"] > h["full"]:
            break
    assert h["without"] > h["full"], h
    cp0 = {k: v for k, v in cp0.items() if any(v)}
    cp0 = {k: v[:max(i + 1 for i, n in enumerate(v) if n)] for k, v in cp0.items()}     # the stored (canonical) form
    w.tick(2)
    for n, x in c.items():
        assert comp_of(x, tid) == cp0, n
    # a 1.3 client (Rita's copy, as such a client keeps it) passes the team on without cp: Lee keeps the comp
    old = same_rev_copy_without_comp(rita, tid)
    assert "cp" not in old and old["rev"] == get_team(rita, tid)["rev"]
    rita.eval("local r, to = ...; ns.Comm:Send({ t = 'RPG', T = r }, 'WHISPER', to, 'data')", old, K("Lee"))
    w.tick(2)
    assert comp_of(lee, tid) == cp0
    # Sam got that copy first (from an older client while the full one hadn't reached him): the full one replaces it
    sam.eval("local id = ...; local r = %s; local copy = {}; for k, v in pairs(r.T[id]) do copy[k] = v end; "
             "copy.cp = nil; r.T[id] = copy" % ROOT, tid)
    assert comp_of(sam, tid) is None and get_team(sam, tid) is not None
    bob.eval("local id, to = ...; ns.Comm:Send({ t = 'RPG', T = %s.T[id] }, 'WHISPER', to, 'data')" % ROOT, tid, K("Sam"))
    w.tick(2)
    assert comp_of(sam, tid) == cp0
    hashes = {n: x.eval("return ns.RaidPlan:GetDigestHash()") for n, x in c.items()}
    assert len(set(hashes.values())) == 1, hashes
    # two edits in the same second, one clearing the comp, both renaming: not an echo, so the plain same-rev rule
    # (the hash) decides, and every client keeps the same version
    gina = c["Gina"]
    assert save(gina, "By Gina", ["Lee", "Rita"], tid, comp=False)["ok"] is True
    assert save(bob, "By Bob", ["Lee", "Rita"], tid)["ok"] is True
    assert gina.eval("return %s.T[...].rev" % ROOT, tid) == bob.eval("return %s.T[...].rev" % ROOT, tid)
    w.tick(2)
    seen = {n: repr((get_team(x, tid)["name"], comp_of(x, tid))) for n, x in c.items()}
    assert len(set(seen.values())) == 1, seen
    hashes = {n: x.eval("return ns.RaidPlan:GetDigestHash()") for n, x in c.items()}
    assert len(set(hashes.values())) == 1, hashes
    # a change made while Sam is away reaches him at his next login (digest -> RPW -> RPG)
    sam.logout()
    w.tick(2)
    cp = dict(STD25, ROGUE=[0, 1], HUNTER=[1, 1, 1])
    assert call(bob, "SetTeamComp", tid, cp)["ok"] is True
    w.tick(2)
    sam.login()
    w.tick(40)
    assert comp_of(sam, tid) == cp
    w.assert_no_errors()


@case
def presets_hold_the_agreed_specs():
    w, c = world()
    rita = c["Rita"]
    ps = rc(rita, "GetPresets")
    assert [(p["key"], p["name"], p["size"]) for p in ps] == [("std25", "Standard 25", 25), ("kara10", "Kara 10", 10)]
    assert ps[0]["cp"] == STD25 and ps[1]["cp"] == KARA10
    assert [p["key"] for p in rc(rita, "GetPresets", 10)] == ["kara10"]
    assert [p["key"] for p in rc(rita, "GetPresets", 25)] == ["std25"]
    assert names(rc(rita, "CompSlots", STD25)) == STD25_SLOTS
    assert names(rc(rita, "CompSlots", KARA10)) == KARA10_SLOTS
    assert rc(rita, "RoleCounts", STD25) == {"tank": 3, "healer": 6, "melee": 7, "ranged": 9}
    assert rc(rita, "RoleCounts", KARA10) == {"tank": 2, "healer": 3, "melee": 2, "ranged": 3}
    assert rc(rita, "CompSize", STD25) == 25 and rc(rita, "CompSize", KARA10) == 10
    # each fits its size and is in the stored form already
    assert rita.eval_py("local a, n = ns.RaidComp:CleanComp(ns.RaidComp:GetPreset('std25').cp, 25); return { a, n }") \
        == [STD25, 25]
    assert rita.eval("return ns.RaidComp:CleanComp(ns.RaidComp:GetPreset('std25').cp, 10)") is False
    # presets are handed out as copies: changing one changes no later start
    assert rita.eval("local p = ns.RaidComp:GetPresets(25)[1]; p.cp.PALADIN[1] = 9; "
                     "return ns.RaidComp:GetPreset('std25').cp.PALADIN[1]") == 2
    assert rc(rita, "GetPreset", "nope") is None
    # slot names (Feral: the form in brackets)
    for (cls, sp), want in {("DRUID", 3): "Feral Druid (Bear)", ("DRUID", 2): "Feral Druid (Cat)",
                            ("DRUID", 4): "Restoration Druid", ("HUNTER", 1): "Beast Mastery Hunter",
                            ("PALADIN", 1): "Holy Paladin"}.items():
        assert rc(rita, "SlotName", cls, sp) == want, (cls, sp)
    w.assert_no_errors()


@case
def start_from_the_team_as_it_is_or_another_teams_comp():
    off = (("Ash", "WARLOCK", 70), ("Brie", "DRUID", 70), ("Cole", "SHAMAN", 70), ("Dane", "HUNTER", 70),
           ("Eve", "PALADIN", 70), ("Finn", "MAGE", 70), ("Gus", "ROGUE", 70), ("Hoff", "PRIEST", 70))
    w, c = world(offline=off)
    bob, rita = c["Bob"], c["Rita"]
    specs = {"Lee": 3, "Gina": 1, "Rita": 2, "Sam": 2, "Bob": 2, "Ash": 3, "Brie": 4, "Cole": 2, "Dane": 2, "Eve": 2,
             "Gus": 2, "Hoff": 1}                                 # Finn: no spec known
    members = list(specs) + ["Finn"]
    ka = team(bob, "Kara A", members, size=10, specs=specs, groups={"Gus": 1, "Hoff": 2})
    kb = team(bob, "Kara B", ["Sam"], size=10, comp={"MAGE": [0, 1]})
    main = team(bob, "Main", ["Lee"], comp=STD25)
    w.tick(2)
    # 12 members with a spec, 10 slots: the seated ones first, then by name (Rita and Sam left out)
    own = {"ROGUE": [0, 1], "PRIEST": [1], "WARLOCK": [0, 0, 1], "MAGE": [0, 1], "DRUID": [0, 0, 0, 1],
           "SHAMAN": [0, 1], "HUNTER": [0, 1], "PALADIN": [1, 1], "WARRIOR": [0, 0, 1]}
    assert rp(rita, "CompFromTeam", ka) == own
    starts = rp(rita, "GetCompStarts", ka)
    assert [(s["key"], s["kind"], s["name"], s["size"]) for s in starts] == [
        ("kara10", "preset", "Kara 10", 10), ("team", "team", "The team as it is", 10),
        ("copy:" + kb, "copy", "Kara B", 10)], starts
    assert starts[0]["cp"] == KARA10 and starts[1]["cp"] == own and starts[2]["cp"] == {"MAGE": [0, 1]}
    assert starts[2]["teamId"] == kb
    # the Teams page's draft (a set of members, s, sz): a new team gets the same choices
    draft = {"members": {K("Lee"): True, K("Finn"): True}, "s": {K("Lee"): 3}, "sz": 10}
    starts = rp(rita, "GetCompStarts", draft)
    assert [s["key"] for s in starts] == ["kara10", "team", "copy:" + kb]
    assert starts[1]["cp"] == {"WARRIOR": [0, 0, 1]}
    # a 25: its preset and the 25s' comps; nobody's spec known, so no "as it is"
    assert [s["key"] for s in rp(rita, "GetCompStarts", {"members": {K("Finn"): True}, "sz": 25})] == \
        ["std25", "copy:" + main]
    # copying another team's comp is a copy: changing that team's comp later changes nothing here
    assert team(bob, "Kara A", members, ka, comp=starts[2]["cp"]) == ka
    assert call(bob, "SetTeamComp", kb, {"MAGE": [0, 2]})["ok"] is True
    w.tick(2)
    assert comp_of(rita, ka) == {"MAGE": [0, 1]} and comp_of(rita, kb) == {"MAGE": [0, 2]}
    assert rp(rita, "GetCompStarts", "nope") == []
    w.assert_no_errors()


@case
def members_fill_their_own_spec_seated_first_and_the_rest_is_bench():
    w, c = world(offline=(("Fern", "DRUID", 70), ("Hex", "WARLOCK", 70), ("Pally", "PALADIN", 70),
                          ("Zed", "PALADIN", 70), ("Ned", "MAGE", 70)))
    bob, rita, sam = c["Bob"], c["Rita"], c["Sam"]
    members = [
        {"key": "Zed-T", "c": "PALADIN", "sp": 1, "seated": True},
        {"key": "Amy-T", "c": "PALADIN", "sp": 1},
        {"key": "Bea-T", "c": "PALADIN", "sp": 1},
        {"key": "Dax-T", "c": "WARLOCK", "sp": 3},              # Destruction: not the Affliction slot
        {"key": "Cub-T", "c": "DRUID", "sp": 2},                # Cat: not the Bear slot
        {"key": "Ned-T", "c": "MAGE"},                          # no spec: bench, last
    ]
    cp = {"PALADIN": [2], "WARLOCK": [1], "DRUID": [0, 0, 1]}
    m = rc(rita, "MatchComp", cp, members)
    assert [(s["name"], s.get("key")) for s in m["slots"]] == [
        ("Feral Druid (Bear)", None), ("Holy Paladin", "Zed-T"), ("Holy Paladin", "Amy-T"),
        ("Affliction Warlock", None)], m["slots"]
    assert [s.get("key") for s in m["columns"]["healer"]] == ["Zed-T", "Amy-T"] and m["columns"]["melee"] == []
    assert [s["role"] for s in m["slots"]] == ["tank", "healer", "healer", "ranged"]
    assert keys(m["bench"]) == ["Bea-T", "Cub-T", "Dax-T", "Ned-T"]
    assert [(o["name"], o["n"], o["role"]) for o in m["open"]] == [("Feral Druid (Bear)", 1, "tank"),
                                                                   ("Affliction Warlock", 1, "ranged")]
    assert (m["filled"], m["total"], m["openCount"]) == (2, 4, 2)
    # the same whatever order the members come in (every client picks the same)
    assert rc(sam, "MatchComp", cp, list(reversed(members))) == m
    opens, n = rita.eval_py("local o, n = ns.RaidComp:OpenSlots(...); return o, n", cp, members)
    assert n == 2 and opens == m["open"]
    # a saved team: classes from the roster, specs from the team; its draft gives the same
    specs = {"Lee": 3, "Pally": 1, "Zed": 1, "Gina": 1, "Hex": 3, "Fern": 2}
    tid = team(bob, "Main", ["Lee", "Pally", "Zed", "Gina", "Hex", "Fern", "Ned"], specs=specs, groups={"Zed": 1},
               comp={"WARRIOR": [0, 0, 1], "PALADIN": [2], "WARLOCK": [1], "DRUID": [0, 0, 1]})
    w.tick(2)
    m = rp(rita, "MatchTeam", tid)
    assert [(s["name"], s.get("key")) for s in m["slots"]] == [
        ("Protection Warrior", K("Lee")), ("Feral Druid (Bear)", None), ("Holy Paladin", K("Zed")),
        ("Holy Paladin", K("Gina")), ("Affliction Warlock", None)], m["slots"]
    assert keys(m["bench"]) == [K("Pally"), K("Fern"), K("Hex"), K("Ned")]
    assert m["bench"][0]["source"] == "team" and m["bench"][3].get("sp") is None
    draft = {"id": tid, "members": {K(n): True for n in specs}, "s": {K(n): sp for n, sp in specs.items()},
             "grp": {K("Zed"): 1}, "cp": {"WARRIOR": [0, 0, 1], "PALADIN": [2], "WARLOCK": [1], "DRUID": [0, 0, 1]}}
    md = rp(rita, "MatchTeam", draft)
    assert [s.get("key") for s in md["slots"]] == [s.get("key") for s in m["slots"]]
    assert keys(md["bench"]) == [K("Pally"), K("Fern"), K("Hex")]   # Ned is not in the draft
    opens = rita.eval_py("local o, n = ns.RaidPlan:GetTeamOpenSlots(...); return { o = o, n = n }", tid)
    assert opens["n"] == 2 and [o["name"] for o in opens["o"]] == ["Feral Druid (Bear)", "Affliction Warlock"]
    # without a comp: no match, nothing open
    draft["cp"] = {}
    assert rp(rita, "MatchTeam", draft) is None
    assert rita.eval_py("local o, n = ns.RaidPlan:GetTeamOpenSlots(...); return { o = o, n = n }", draft) == \
        {"o": [], "n": 0}
    w.assert_no_errors()


@case
def can_fill_lists_bench_alts_guild_and_other_teams_in_order():
    names_ = NAMES + (("Hal", 3, "HUNTER"), ("Hunt", 3, "HUNTER"), ("Vic", 3, "HUNTER"))
    off = (("Bram", "HUNTER", 70), ("Quiver", "HUNTER", 70), ("Kenji", "HUNTER", 70), ("Orin", "HUNTER", 70),
           ("Tarrok", "HUNTER", 70), ("Lunaris", "HUNTER", 70), ("Sylwen", "HUNTER", 60), ("Banned", "HUNTER", 70),
           ("Aegis", "PALADIN", 70), ("Newbie", "HUNTER", 70))
    w, c = world(names_, offline=off, pairs=(("Lee", "Hunt"), ("Sam", "Vic")))
    gina, bob = c["Gina"], c["Bob"]
    assert gina.eval("return ns.Guild:SameAccount(...)", K("Lee"), K("Hunt")) is True
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(c["Hunt"], occ, "A", 3)["ok"] is True           # Survival
    assert signup(c["Vic"], occ, "A", 1)["ok"] is True            # Beast Mastery
    main = team(bob, "Main", ["Lee", "Sam", "Rita", "Hal", "Bram", "Quiver"],
                specs={"Lee": 3, "Sam": 2, "Rita": 2, "Hal": 1, "Bram": 1},
                comp={"WARRIOR": [0, 0, 1], "ROGUE": [0, 1], "PRIEST": [0, 1], "HUNTER": [0, 0, 1], "PALADIN": [1]})
    kb = team(bob, "Kara B", ["Kenji", "Orin", "Hunt", "Aegis"], size=10,
              specs={"Kenji": 3, "Orin": 2, "Hunt": 3, "Aegis": 1})
    w.tick(2)
    assert gina.eval("local ok = ns.RaidPlan:SetBlacklisted('Banned'); return ok") is True
    assert gina.eval("return ns.BiS:SetSpec('Holy')") is not False
    w.tick(2)
    # Gina reads (she is on no team): the answers of members without a client, as received earlier
    inject_signups(gina, "zz1", {"Tarrok": ("A", "HUNTER", 3), "Lunaris": ("T", "HUNTER", 3),
                                 "Sylwen": ("A", "HUNTER", 3), "Banned": ("A", "HUNTER", 3), "Orin": ("A", "HUNTER", 3)})
    f = rp(gina, "CanFill", main, "HUNTER", 3)
    assert [(e["key"], e["other"], e["online"], e.get("sp")) for e in f["bench"]] == [
        (K("Hal"), True, True, 1), (K("Bram"), True, False, 1), (K("Quiver"), True, False, None)], f["bench"]
    assert [(e["key"], e["other"], e["of"], e.get("sp")) for e in f["alts"]] == [
        (K("Hunt"), False, K("Lee"), 3), (K("Vic"), True, K("Sam"), 1)], f["alts"]
    # level 60, blacklisted, on a team (Orin plays Marksmanship there): left out
    assert [(e["key"], e["other"]) for e in f["guild"]] == [(K("Lunaris"), False), (K("Tarrok"), False)], f["guild"]
    assert [(e["key"], e["team"], e["teamId"], e["other"]) for e in f["teams"]] == [(K("Kenji"), "Kara B", kb, False)]
    listed = [e["key"] for g in ("bench", "alts", "guild", "teams") for e in f[g]]
    assert len(listed) == len(set(listed))                       # Hunt (alt and on Kara B) shows once
    # the same lists on another client (Bob reads the same data; online may differ, the order may not)
    inject_signups(bob, "zz1", {"Tarrok": ("A", "HUNTER", 3), "Lunaris": ("T", "HUNTER", 3),
                                "Sylwen": ("A", "HUNTER", 3), "Banned": ("A", "HUNTER", 3), "Orin": ("A", "HUNTER", 3)})
    fb = rp(bob, "CanFill", main, "HUNTER", 3)
    assert {g: keys(fb[g]) for g in fb} == {g: keys(f[g]) for g in f}
    # the Holy Paladin slot: Gina by her BiS list (on no team), Aegis by Kara B; no bench / alt of that class
    f = rp(gina, "CanFill", main, "PALADIN", 1)
    assert f["bench"] == [] and f["alts"] == [] and keys(f["guild"]) == [K("Gina")] and keys(f["teams"]) == [K("Aegis")]
    assert f["guild"][0]["online"] is True
    idx = rp(gina, "GetSpecIndex")
    assert idx["byKey"][K("Gina")] == {"c": "PALADIN", "sp": 1, "src": "bis"}
    assert K("Sylwen") not in idx["byKey"]
    # a new answer: the index is built again after the change (RAIDPLAN_CHANGED), not kept for 30 seconds
    inject_signups(gina, "zz1", {"Newbie": ("A", "HUNTER", 3)})
    f = rp(gina, "CanFill", main, "HUNTER", 3)
    assert keys(f["guild"]) == [K("Lunaris"), K("Newbie"), K("Tarrok")], f["guild"]
    # Quiver's answer as Survival: he takes the open slot, and the bench keeps the two Beast Masteries
    inject_signups(gina, "zz1", {"Quiver": ("A", "HUNTER", 3)})
    assert rp(gina, "GetTeamOpenSlots", main) == [{"c": "PALADIN", "sp": 1, "role": "healer", "name": "Holy Paladin",
                                                    "n": 1}]
    f = rp(gina, "CanFill", main, "HUNTER", 3)
    assert keys(f["bench"]) == [K("Hal"), K("Bram")]
    # bad specs, unknown teams: nothing
    for args in ((main, "BARD", 1), (main, "PALADIN", 4), (main, "PALADIN", 0), ("nope", "HUNTER", 3)):
        assert rp(gina, "CanFill", *args) == {"bench": [], "alts": [], "guild": [], "teams": []}, args
    w.assert_no_errors()


@case
def a_raid_shows_the_open_slots_of_its_teams_comp():
    off = (("Aegis", "PALADIN", 70), ("Fern", "DRUID", 70), ("Storm", "SHAMAN", 70), ("Hex", "WARLOCK", 70),
           ("Kaelyn", "HUNTER", 70), ("Shieldy", "PALADIN", 70), ("Benchy", "PALADIN", 70), ("Lowpal", "PALADIN", 60))
    w, c = world(offline=off)
    gina, bob, lee, rita, sam = c["Gina"], c["Bob"], c["Lee"], c["Rita"], c["Sam"]
    specs = {"Lee": 3, "Gina": 1, "Aegis": 2, "Rita": 2, "Fern": 4, "Sam": 2, "Storm": 2, "Bob": 2, "Hex": 3, "Kaelyn": 2}
    ka = team(bob, "Kara A", list(specs), size=10, specs=specs, comp=KARA10)
    main = team(bob, "Main", ["Lee"], comp=STD25)
    plain = team(bob, "No comp", ["Lee"], size=10)
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[main, ka])     # the first team with a comp of size 10
    w.tick(2)
    assert signup(lee, occ, "A", 3)["ok"] is True
    assert signup(gina, occ, "A", 1)["ok"] is True
    assert signup(rita, occ, "T", 2)["ok"] is True                # Tentative fills
    assert signup(sam, occ, "B", 2)["ok"] is True                 # Bench doesn't
    assert signup(bob, occ, "X", 2)["ok"] is True                 # nor Absent
    assert call(bob, "AddGuest", occ, "Pugsy", "HUNTER", 2)["ok"] is True   # a guest fills by class and spec
    w.tick(2)
    # answers of members without a client, as received: Fern without a spec (the team's), Hex as Affliction (not the
    # Destruction slot), Benchy on the bench; Shieldy's and Lowpal's answers are for another raid
    inject_signups(rita, occ, {"Fern": ("A", "DRUID", None), "Storm": ("A", "SHAMAN", 2), "Hex": ("A", "WARLOCK", 1),
                               "Benchy": ("B", "PALADIN", 2)})
    inject_signups(rita, "zz1", {"Shieldy": ("A", "PALADIN", 2), "Lowpal": ("A", "PALADIN", 2)})
    o = rp(rita, "GetRaidOpenSlots", occ)
    assert (o["teamId"], o["teamName"], o["size"], o["wanted"], o["filled"], o["openCount"]) == (ka, "Kara A", 10, 10, 6, 4), o
    assert [(x["name"], x["n"], x["role"]) for x in o["open"]] == [
        ("Protection Paladin", 1, "tank"), ("Combat Rogue", 1, "melee"), ("Fire Mage", 1, "ranged"),
        ("Destruction Warlock", 1, "ranged")], o["open"]
    assert [(x["c"], x["sp"], x["role"]) for x in o["slots"]] == [
        ("PALADIN", 2, "tank"), ("ROGUE", 2, "melee"), ("MAGE", 2, "ranged"), ("WARLOCK", 3, "ranged")]
    filled = {s["name"]: s.get("key") for s in o["match"]["slots"] if s.get("key")}
    assert filled == {"Protection Warrior": K("Lee"), "Holy Paladin": K("Gina"), "Holy Priest": K("Rita"),
                      "Restoration Druid": K("Fern"), "Enhancement Shaman": K("Storm"),
                      "Marksmanship Hunter": K("Pugsy")}, filled
    # who could fill the Protection Paladin slot: the member who hasn't answered, then the guild (Benchy on the
    # bench, Shieldy; Lowpal is level 60)
    f = rp(rita, "RaidCanFill", occ, "PALADIN", 2)
    assert [(e["key"], e["online"]) for e in f["unanswered"]] == [(K("Aegis"), False)]
    assert [(e["key"], e.get("st")) for e in f["guild"]] == [(K("Benchy"), "B"), (K("Shieldy"), None)]
    # Bob answered Absent: his Fire Mage slot is open, and he is not "unanswered"
    assert rp(rita, "RaidCanFill", occ, "MAGE", 2) == {"unanswered": [], "guild": []}
    # Sam turns Accepted: Combat Rogue is filled
    assert signup(sam, occ, "A", 2)["ok"] is True
    w.tick(2)
    o = rp(rita, "GetRaidOpenSlots", occ)
    assert o["filled"] == 7 and [x["name"] for x in o["open"]] == ["Protection Paladin", "Fire Mage",
                                                                   "Destruction Warlock"]
    # the raid's buff strip: lit = the Accepted / Tentative answers, planned = the open slots
    st = {b["key"]: b for b in rp(rita, "GetRaidBuffStates", occ)}
    assert st["arcaneint"]["state"] == "planned" and names(st["impscorch"]["slots"]) == ["Fire Mage"]
    assert st["coe"]["state"] == "have" and st["coe"]["providers"] == [K("Hex")]
    assert st["fortitude"]["state"] == "have" and st["fortitude"]["providers"] == [K("Rita")]
    assert st["exposeweakness"]["state"] == "off"
    # no open slots: a raid whose teams have no comp of its size, a cancelled raid, an unknown raid
    occ25 = create(bob, i="ssc", t=now(bob) + 2 * DAY, tm=[ka])
    occ_plain = create(bob, i="kara", t=now(bob) + 3 * DAY, tm=[plain])
    occ_open = create(bob, i="kara", t=now(bob) + 4 * DAY)
    w.tick(2)
    for x in (occ25, occ_plain, occ_open, "nope"):
        assert rp(rita, "GetRaidOpenSlots", x) is None, x
        assert rp(rita, "RaidCanFill", x, "PALADIN", 2) == {"unanswered": [], "guild": []}, x
    assert rp(rita, "GetRaidCompTeam", occ)["id"] == ka
    assert call(bob, "CancelRaid", occ)["ok"] is True
    w.tick(2)
    assert rp(rita, "GetRaidOpenSlots", occ) is None
    w.assert_no_errors()


@case
def the_buff_strip_has_three_states():
    w, c = world(offline=(("Pally", "PALADIN", 70), ("Brie", "DRUID", 70)))
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Main", ["Gina", "Pally", "Lee", "Brie", "Sam"], specs={"Gina": 1, "Pally": 1, "Lee": 3, "Brie": 4},
               comp={"PALADIN": [2], "HUNTER": [0, 0, 1], "DRUID": [0, 0, 0, 1], "PRIEST": [0, 0, 1],
                     "WARRIOR": [0, 0, 1]})
    w.tick(2)
    st = rp(rita, "GetTeamBuffStates", tid)
    assert [b["key"] for b in st] == ["blessings", "fortitude", "divinespirit", "motw", "arcaneint", "sunder",
                                      "bloodfrenzy", "faeriefire", "huntersmark", "exposeweakness", "coe", "misery",
                                      "impscorch", "jow"]
    by = {b["key"]: b for b in st}
    want = {"blessings": "have", "fortitude": "planned", "divinespirit": "off", "motw": "have", "arcaneint": "off",
            "sunder": "have", "bloodfrenzy": "off", "faeriefire": "have", "huntersmark": "planned",
            "exposeweakness": "planned", "coe": "off", "misery": "planned", "impscorch": "off", "jow": "have"}
    assert {k: b["state"] for k, b in by.items()} == want
    assert by["blessings"]["providers"] == [K("Gina"), K("Pally")] and by["blessings"]["count"] == 2
    assert by["motw"]["providers"] == [K("Brie")]                 # Sam (a rogue, bench) brings nothing here
    assert names(by["exposeweakness"]["slots"]) == ["Survival Hunter"]
    assert names(by["fortitude"]["slots"]) == ["Shadow Priest"] and by["fortitude"]["providers"] == []
    assert [(x["c"], x.get("sp"), x["name"]) for x in by["bloodfrenzy"]["bringers"]] == [("WARRIOR", 1, "Arms Warrior")]
    assert [(x["c"], x.get("sp"), x["name"]) for x in by["arcaneint"]["bringers"]] == [("MAGE", None, "Mage")]
    assert [x["name"] for x in by["divinespirit"]["bringers"]] == ["Discipline Priest"]
    # without a comp: the members, nothing planned
    assert call(bob, "SetTeamComp", tid, False)["ok"] is True
    w.tick(2)
    by = {b["key"]: b for b in rp(rita, "GetTeamBuffStates", tid)}
    assert by["exposeweakness"]["state"] == "off" and by["motw"]["state"] == "have"
    # the pure call (a Groups tab: who is in the groups, the comp's open slots)
    by = {b["key"]: b for b in rc(rita, "BuffStates", [{"key": "A-T", "c": "MAGE", "sp": 2}], [{"c": "HUNTER", "sp": 3}])}
    assert by["arcaneint"]["state"] == "have" and by["impscorch"]["state"] == "have"
    assert by["huntersmark"]["state"] == "planned" and by["sunder"]["state"] == "off"
    w.assert_no_errors()


@case
def the_lf_line_names_the_open_specs_and_the_next_raid():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    comp = {"PALADIN": [2], "DRUID": [0, 0, 0, 1], "HUNTER": [0, 0, 1], "WARRIOR": [0, 0, 1]}
    tid = team(bob, "Main", ["Gina", "Lee"], specs={"Gina": 1, "Lee": 3}, comp=comp)
    w.tick(2)
    # no raid yet
    assert rp(rita, "GetLFMessage", tid) == "<Casual Disaster> LF Holy Paladin, Restoration Druid, Survival Hunter · /w me"
    # the next raid that invites the team: a Sunday 20:00 in Serpentshrine (an older one and a cancelled one don't count)
    sun = bob.eval("local t = GetServerTime() + 86400; local d = date('*t', t); d.day = d.day + (8 - d.wday) % 7; "
                   "d.hour, d.min, d.sec, d.isdst = 20, 0, 0, nil; return time(d)")
    occ = create(bob, i="ssc", t=sun, tm=[tid])
    later = create(bob, i="tk", t=sun + 2 * DAY, tm=[tid])
    first = create(bob, i="gruul", t=sun - 3600 * 5, tm=[tid])
    assert call(bob, "CancelRaid", first)["ok"] is True
    w.tick(2)
    assert rp(rita, "GetTeamNextRaid", tid)["id"] == occ
    assert later and rp(rita, "GetLFMessage", tid) == \
        "<Casual Disaster> LF Holy Paladin, Restoration Druid, Survival Hunter · SSC Sun 20:00 · /w me"
    # two open of a spec; a draft works too (the team's id finds the raid)
    draft = {"id": tid, "members": {K("Lee"): True}, "s": {K("Lee"): 3}, "cp": {"PALADIN": [2], "WARRIOR": [0, 0, 1]}}
    assert rp(rita, "GetLFMessage", draft) == "<Casual Disaster> LF Holy Paladin ×2 · SSC Sun 20:00 · /w me"
    # nothing open: no line
    draft["cp"] = {"WARRIOR": [0, 0, 1]}
    assert rp(rita, "GetLFMessage", draft) is None
    draft["cp"] = {}
    assert rp(rita, "GetLFMessage", draft) is None
    assert rp(rita, "GetLFMessage", "nope") is None
    # 25 different specs open: at most 255 bytes, the last specs become "+n more" (as many named as fit)
    big = {"WARRIOR": [1, 1, 1], "PALADIN": [1, 1, 1], "HUNTER": [0, 1, 1], "ROGUE": [0, 1, 1], "PRIEST": [1, 1, 1],
           "SHAMAN": [1, 1, 1], "MAGE": [1, 1], "WARLOCK": [1, 1, 1], "DRUID": [1, 1, 1, 1]}
    line = rp(rita, "GetLFMessage", {"members": {}, "cp": big})
    order = names(rc(rita, "CompSlots", big))
    assert len(order) == 25
    head, tail = "<Casual Disaster> LF ", " · /w me"
    want = None
    for keep in range(25, 0, -1):
        parts = order[:keep] + (["+%d more" % (25 - keep)] if keep < 25 else [])
        s = head + ", ".join(parts) + tail
        if len(s.encode("utf-8")) <= 255:
            want = s
            break
    assert line == want and "more · /w me" in line and len(line.encode("utf-8")) <= 255, line
    assert rc(rita, "LFLine", "G", [], None) is None
    assert rc(rita, "LFLine", None, [{"name": "Fire Mage", "n": 1}], "") == "LF Fire Mage · /w me"
    w.assert_no_errors()


@case
def hostile_comps_are_refused_whole():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    bad = [
        "'x'", "{ BARD = { 1 } }", "{ PALADIN = 'x' }", "{ PALADIN = { 26 } }", "{ PALADIN = { -1 } }",
        "{ PALADIN = { 1.5 } }", "{ PALADIN = { 0, 0, 0, 1 } }", "{ PALADIN = { [0] = 1 } }", "{ PALADIN = { x = 1 } }",
        "{ PALADIN = { 1/0 } }", "{ [1] = { 1 } }", "{}", "{ PALADIN = { 0, 0, 0 } }", "{ PALADIN = { 25 }, MAGE = { 1 } }",
        "(function() local t = {}; for i = 1, 3000 do t[i] = 1 end; return { PALADIN = t } end)()",
        "(function() local t = {}; for i = 1, 300 do t['K' .. i] = { 1 } end; return t end)()",
    ]
    for i, cp in enumerate(bad):
        bob.eval("local id = ...; ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = id, rev = GetServerTime(), "
                 "by = ns.Util.PlayerKey(), n = 'Bad', m = { ns.Util.PlayerKey() }, cp = %s } }, 'GUILD', nil, 'data')" % cp,
                 "h%d" % i)
    # more slots than the record's size (10)
    bob.eval("ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = 'hsz', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
             "n = 'Bad', m = {}, sz = 10, cp = { PALADIN = { 11 } } } }, 'GUILD', nil, 'data')")
    # a good one by the same way: stored in its canonical form
    bob.eval("ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = 'good', rev = GetServerTime(), by = ns.Util.PlayerKey(), "
             "n = 'Good', m = {}, sz = 10, cp = { PALADIN = { 2, 0, 0 }, MAGE = { 0, 0, 0 } } } }, 'GUILD', nil, 'data')")
    # (the bulk queue spreads the 18 messages over several seconds; the last one sent is the good one)
    w.run_until(lambda: all(x.eval("local r = ns.db.raidplan and %s; return r ~= nil and r.T.good ~= nil" % ROOT)
                            for x in (rita, lee)), timeout=40)
    w.tick(1)
    for x in (rita, lee):
        stored = x.eval_py("local out = {}; for id in pairs(%s.T) do out[#out + 1] = id end; table.sort(out); "
                           "return out" % ROOT)
        assert stored == ["good"], (x.name, stored)
        assert comp_of(x, "good") == {"PALADIN": [2]}
    # the same checks on the UI's way in
    for cp in ('"x"', "{ PALADIN = { 26 } }", "{ BARD = { 1 } }", "{ PALADIN = { 0, 0, 0, 1 } }"):
        res = bob.eval_py("local ok, e = ns.RaidPlan:SaveTeam(nil, 'T', {}, { comp = %s }); return { ok = ok, e = e }" % cp)
        assert res["ok"] is False and res["e"] == "That target comp is not valid.", (cp, res)
    # CleanComp itself: nil = no comp, false = invalid
    assert rita.eval("return ns.RaidComp:CleanComp(nil)") is None
    assert rita.eval("return ns.RaidComp:CleanComp({})") is None
    for cp in ("{ PALADIN = { 0/0 } }", "{ [true] = { 1 } }", "{ PALADIN = { [1.5] = 1 } }", "{ PALADIN = { 11 } }"):
        assert rita.eval("return ns.RaidComp:CleanComp(%s, 10)" % cp) is False, cp
    # junk members, bad slots: no error, nothing taken
    m = rita.eval_py("return ns.RaidComp:MatchComp({ MAGE = { 0, 1 } }, { 'x', 5, { key = 3 }, "
                     "{ key = 'A-B', c = 'BARD', sp = 1 }, { key = 'A-B', c = 'MAGE', sp = 2 }, "
                     "{ key = 'C-D', c = 'MAGE', sp = 'x' }, { key = 'E-F', c = 'MAGE', sp = 2, seated = 'yes' } })")
    assert [s.get("key") for s in m["slots"]] == ["E-F"] and keys(m["bench"]) == ["A-B", "C-D"]
    assert rita.eval_py("return ns.RaidComp:MatchComp('x', 'y')")["total"] == 0
    assert rc(rita, "CompSize", "x") == 0 and rc(rita, "CopyComp", None) is None
    assert rc(rita, "SameComp", None, {}) is True and rc(rita, "SameComp", {"MAGE": [0, 1]}, {"MAGE": [0, 1, 0]}) is True
    assert rc(rita, "SameComp", {"MAGE": [1]}, {"MAGE": [0, 1]}) is False
    # SetCount keeps the stored form and the limits
    assert rita.eval_py("local cp = { MAGE = { 1 } }; ns.RaidComp:SetCount(cp, 'PALADIN', 1, 99); "
                        "ns.RaidComp:SetCount(cp, 'PALADIN', 9, 1); ns.RaidComp:SetCount(cp, 'BARD', 1, 1); "
                        "ns.RaidComp:SetCount(cp, 'MAGE', 1, 0); ns.RaidComp:SetCount(cp, 'DRUID', 3, 2); return cp") \
        == {"PALADIN": [25], "DRUID": [0, 0, 2]}
    assert rp(rita, "ResolveTeam", 5) is None and rp(rita, "GetTeamMembers", "nope") == []
    # nothing random in the comp code (the same comp, bench and lists on every client)
    import harness
    for rel, marker in (("Core/RaidComp.lua", "-- Target comp (1.3.1)"), ("Core/RaidPlan.lua", "-- Target comp (1.3.1)")):
        with open(os.path.join(harness.ADDON_DIR, rel), "rb") as fh:
            src = fh.read().decode("utf-8")
        part = src[src.index(marker):]
        if rel.endswith("RaidPlan.lua"):
            part = part[:part.index("-- Public API: writing (organizers)")]
        assert "random" not in part.lower(), rel
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
