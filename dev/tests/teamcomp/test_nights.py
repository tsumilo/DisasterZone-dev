"""Raids > Teams, raid nights (1.3.5, user decisions 2026-10-10), on the real addon.

Covers: Core/RaidNights.lua (clean nights from the wire, realm time <-> my clock across the week's ends, the summary
lines); nights and a note saved with the team, synced, kept by an edit that doesn't name them, cleared, bad ones
refused on save and dropped (never the team) from the wire; an older client's copies and edits keeping them; a player
in another time zone seeing them in their own clock; two organizers' crossing edits keeping both; the Teams page (the
board's banners, the team's banner for organizers and members, the editor: day tiles, hours, Optional, the note, Save
and Undo, closed when leaving the team) and the waitlist panel showing them before Join.

Run: luaenv\\Scripts\\python.exe tests\\teamcomp\\test_nights.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

NAMES = (("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"))
ROOT = "ns.db.raidplan[ns.Guild:GetGuildKey()]"
P = "ns.RaidsUI:GetPanel()"
TV = P + ".teams"
D = TV + ".detail"
THU, SUN = 3 * 1440 + 19 * 60 + 30, 6 * 1440 + 19 * 60 + 30       # Thu / Sun 19:30 in realm time (w)
NIGHTS = [{"w": THU, "m": 210}, {"w": SUN, "m": 210, "o": True}]
NOTE = "Online 15 min before invites."


def world(names=NAMES):
    w = World()
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    w.tick(2)
    return w, c


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def save(cl, tid, name, members, **opts):
    return cl.eval_py("local id, n, m, o = ...; local ok, r = ns.RaidPlan:SaveTeam(id, n, m, o); return { ok = ok, r = r }",
                      tid, name, [K(m) for m in members], opts)


def team(cl, name, members, **opts):
    res = save(cl, None, name, members, **opts)
    assert res["ok"] is True, res
    return res["r"]


def get_team(cl, tid):
    return cl.eval_py("return ns.RaidPlan:GetTeam(...)", tid)


def nights(cl, tid):
    t = get_team(cl, tid)
    return [{k: v for k, v in n.items()} for n in lst(t["nights"])] if t else None


def rn(cl, fn, *args):
    return cl.eval_py("local fn = ...; return { ns.RaidNights[fn](ns.RaidNights, select(2, ...)) }", fn, *args)


def open_teams(w, cl, tid=None):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('teams')")
    if tid:
        cl.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def text(cl, expr):
    return strip_codes(cl.eval("return %s:GetText()" % expr) or "")


# ------------------------------------------------------------------------------------------------------------------
@case
def the_nights_module():
    w, c = world((("Gina", 0, "PALADIN"),))
    g = c["Gina"]
    # clean: sorted by start, optional kept, bad ones refused whole
    out = rn(g, "Clean", [NIGHTS[1], NIGHTS[0]])[0]
    assert [n["w"] for n in lst(out)] == [THU, SUN] and lst(out)[1].get("o") is True, out
    assert lst(rn(g, "Clean", False)[0]) == []
    for bad in ([{"w": THU, "m": 0}], [{"w": THU + 7, "m": 60}], [{"w": 10080, "m": 60}], [{"w": THU, "m": 1440}],
                [{"w": THU, "m": 60}, {"w": THU, "m": 90}], [{"w": THU, "m": 60, "o": 1}], "x",
                [{"w": i * 1440, "m": 60} for i in range(7)] + [{"w": 60, "m": 60}]):
        assert rn(g, "Clean", bad)[0] is False, bad
    assert rn(g, "Clean", None) == []
    # my clock = realm time here: Thursday 19:30 - 23:00
    assert rn(g, "Local", NIGHTS[0], 0) == [4, 1170, 1380, False]
    assert rn(g, "TimesText", NIGHTS, 0) == ["19:30 – 23:00", "Sun optional"]
    assert rn(g, "DaysText", NIGHTS, 0) == ["Thu + Sun"]
    assert rn(g, "DaysText", NIGHTS[:1], 0) == ["Thursday"]
    # a night past midnight, and one an hour ahead of the realm moving into the next week
    n = rn(g, "FromLocal", 7, 23 * 60, 1 * 60, False, 60)[0]
    assert n == {"w": 6 * 1440 + 22 * 60, "m": 120}, n
    assert rn(g, "Local", n, 60) == [7, 1380, 60, False]
    assert rn(g, "Local", {"w": 30, "m": 60}, -60) == [7, 1410, 30, False]           # Mon 00:30 realm = Sun 23:30
    assert rn(g, "FromLocal", 2, 1200, 1200, False, 0) == []                           # no time: none
    two = [{"w": 1200, "m": 180}, {"w": 2 * 1440 + 1260, "m": 180}]
    assert rn(g, "TimesText", two, 0) == ["Mon 20:00 · Wed 21:00"]
    # my clock against the realm's: an hour ahead
    g.eval("_G.__ggt = GetGameTime; GetGameTime = function() local h, m = __ggt(); return (h + 23) % 24, m end")
    assert rn(g, "Offset") == [60]
    w.assert_no_errors()


@case
def nights_are_saved_synced_kept_and_cleared():
    w, c = world()
    bob, lee = c["Bob"], c["Lee"]
    tid = team(bob, "Main", ["Lee", "Rita"], nights=NIGHTS, note=NOTE)
    w.tick(2)
    for x in (bob, lee, c["Rita"]):
        assert nights(x, tid) == [{"w": THU, "m": 210}, {"w": SUN, "m": 210, "o": True}], nights(x, tid)
        assert get_team(x, tid).get("note") == NOTE
    # an edit that doesn't name them (the comp, the roster) keeps them
    assert lee.eval("return true")
    res = bob.eval_py("local ok, e = ns.RaidPlan:SetTeamComp(..., { WARRIOR = { 0, 0, 1 } }); return { ok = ok, e = e }",
                      tid)
    assert res["ok"] is True, res
    res = save(bob, tid, "Main", ["Lee", "Rita", "Gina"])
    assert res["ok"] is True, res
    w.tick(2)
    assert len(nights(lee, tid)) == 2 and get_team(lee, tid).get("note") == NOTE
    # bad ones are refused on save
    for o in ({"nights": [{"w": THU, "m": 7}]}, {"note": "a|cffff0000b"}, {"note": "x" * 121}):
        res = save(bob, tid, "Main", ["Lee"], **o)
        assert res["ok"] is False and res["r"], (o, res)
    # cleared: false (none) is written
    res = save(bob, tid, "Main", ["Lee", "Rita", "Gina"], nights=False, note=False)
    assert res["ok"] is True, res
    w.tick(2)
    assert nights(lee, tid) == [] and get_team(lee, tid).get("note") is None
    assert lee.eval("return %s.T[...].nt" % ROOT, tid) is False
    # only organizers save teams
    res = save(lee, tid, "Main", ["Lee"], nights=NIGHTS)
    assert res["ok"] is False
    w.assert_no_errors()


@case
def an_older_clients_copies_and_edits_keep_the_nights():
    w, c = world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    tid = team(bob, "Main", ["Lee", "Rita"], nights=NIGHTS, note=NOTE)
    w.tick(2)
    # a 1.3.4 client's copy of this version drops nt and nn: it never replaces the full one
    old = rita.eval_py("local t = %s.T[...]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; "
                       "copy.nt, copy.nn = nil, nil; return copy" % ROOT, tid)
    rita.eval("local r, to = ...; ns.Comm:Send({ t = 'RPG', T = r }, 'WHISPER', to, 'data')", old, K("Lee"))
    w.tick(2)
    assert len(nights(lee, tid)) == 2 and get_team(lee, tid).get("note") == NOTE
    # an edit made on such a client (newer, no nt): the roster changes, the nights and note stay
    edit = bob.eval_py("local t = %s.T[...]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; "
                       "copy.nt, copy.nn = nil, nil; copy.rev = t.rev + 10; copy.m = { select(2, ...) }; return copy"
                       % ROOT, tid, K("Lee"))
    bob.eval("local r = ...; ns.Comm:Send({ t = 'RPU', k = 'T', r = r }, 'GUILD', nil, 'data')", edit)
    w.tick(2)
    for n in ("Lee", "Rita", "Gina"):
        t = get_team(c[n], tid)
        assert lst(t["members"]) == [K("Lee")], (n, t["members"])
        assert len(lst(t["nights"])) == 2 and t.get("note") == NOTE, (n, t)
    # nights a client can't read (a newer format, or made up) are dropped, the team is kept
    bad = bob.eval_py("local t = %s.T[...]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; "
                      "copy.rev = t.rev + 20; copy.n = 'Main 2'; copy.nt = { { w = 5, m = 1 } }; return copy" % ROOT, tid)
    bob.eval("local r = ...; ns.Comm:Send({ t = 'RPU', k = 'T', r = r }, 'GUILD', nil, 'data')", bad)
    w.tick(2)
    t = get_team(lee, tid)
    assert t["name"] == "Main 2", t
    w.assert_no_errors()


@case
def another_time_zone_sees_its_own_clock():
    w, c = world()
    bob, lee = c["Bob"], c["Lee"]
    # Lee's clock is an hour ahead of the realm
    lee.eval("_G.__ggt = GetGameTime; GetGameTime = function() local h, m = __ggt(); return (h + 23) % 24, m end")
    tid = team(bob, "Main", ["Lee", "Rita"], nights=NIGHTS)
    w.tick(2)
    times = lee.eval_py("local t = ns.RaidPlan:GetTeam(...); return { ns.RaidNights:TimesText(t.nights) }", tid)
    assert times == ["20:30 – 00:00", "Sun optional"], times
    # Lee as organizer would write in his clock: Thursday 20:30 his = 19:30 realm
    n = lee.eval_py("return ns.RaidNights:FromLocal(4, 20 * 60 + 30, 0, false)")
    assert n == {"w": THU, "m": 210}, n
    w.assert_no_errors()


@case
def crossing_edits_keep_both():
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    tid = team(bob, "Main", ["Lee", "Rita"], nights=NIGHTS[:1])
    w.tick(2)
    base = get_team(bob, tid)
    base_g = get_team(gina, tid)
    # Gina renames it; Bob, from the same version, changes the nights only
    res = gina.eval_py("local id, b = ...; local ok, r = ns.RaidPlan:SaveTeam(id, 'Main team', b.members, "
                       "{ lineups = b.lineups, base = b }); return { ok = ok, r = r }", tid, base_g)
    assert res["ok"] is True, res
    w.tick(2)
    res = bob.eval_py("local id, b, nt = ...; local ok, r, merged = ns.RaidPlan:SaveTeam(id, b.name, b.members, "
                      "{ lineups = b.lineups, base = b, nights = nt, note = 'Flasks' }); "
                      "return { ok = ok, r = r, merged = merged }", tid, base, NIGHTS)
    assert res["ok"] is True and res["merged"] is True, res
    w.tick(2)
    for x in (bob, gina, c["Lee"]):
        t = get_team(x, tid)
        assert t["name"] == "Main team" and len(lst(t["nights"])) == 2 and t.get("note") == "Flasks", t
    w.assert_no_errors()


@case
def the_teams_page_and_the_editor():
    w, c = world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    tid = team(bob, "Main", ["Lee"], nights=NIGHTS, note=NOTE)
    plain = team(bob, "Alt", ["Lee"])
    w.tick(2)
    # the board: the block on the banner with nights, none on the one without
    open_teams(w, lee)
    lee.eval("ns.RaidPlanUI:ShowTeamBoard()")
    w.tick(0.3)
    cards = lee.eval_py("local out = {}; for _, c in ipairs(%s.board.cards) do if c:IsShown() then "
                        "out[#out + 1] = { id = c.id, n = c.nights and c.nights:IsShown() or false, "
                        "t = c.nights and c.nights.times:GetText() or '' } end end; return out" % TV)
    by = {x["id"]: x for x in lst(cards)}
    assert by[tid]["n"] is True and strip_codes(by[tid]["t"]) == "19:30 – 23:00  ·  Sun optional", by
    assert by[plain]["n"] is False, by
    # a member's banner: read only
    lee.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)
    assert shown(lee, TV + ".card.nights") and lee.eval("return %s.card.nights.editable" % TV) is False
    lee.click(lee.eval("return %s.card.nights" % TV))
    assert not lee.eval("local p = %s.nightsPanel; return p ~= nil and p:IsShown()" % TV)
    # an organizer: a team without nights says Set raid nights; the editor adds them
    open_teams(w, bob, plain)
    assert shown(bob, TV + ".card.nights.add")
    bob.click(bob.eval("return %s.card.nights" % TV))
    w.tick(0.5)
    assert shown(bob, TV + ".nightsPanel")
    tiles = TV + ".nightsPanel.tiles"
    bob.click(bob.eval("return %s[2]" % tiles))
    bob.click(bob.eval("return %s[5]" % tiles))
    w.tick(0.3)
    rows = TV + ".nightsPanel.rows"
    assert text(bob, rows + "[1].day") == "Tuesday" and text(bob, rows + "[2].day") == "Friday"
    assert text(bob, rows + "[2].from.fs") == "19:30" and text(bob, rows + "[2].to.fs") == "23:00"
    bob.click(bob.eval("return %s[2].from.up" % rows))
    bob.click(bob.eval("return %s[2].to.down" % rows))
    bob.click(bob.eval("return %s[2].opt" % rows))
    bob.type_text(bob.eval("return %s.nightsPanel.note" % TV), "Flasks on")
    w.tick(0.3)
    assert text(bob, rows + "[2].from.fs") == "19:45" and text(bob, rows + "[2].to.fs") == "22:45"
    assert shown(bob, D + ".saveBtn") and "changed, not saved" in strip_codes(bob.eval("return %s.card.changed:GetText()"
                                                                                          % TV))
    # untick Tuesday again, then Save
    bob.click(bob.eval("return %s[2]" % tiles))
    bob.click(bob.eval("return %s.nightsPanel.done" % TV))
    assert not shown(bob, TV + ".nightsPanel")
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(2)
    assert nights(lee, plain) == [{"w": 4 * 1440 + 19 * 60 + 45, "m": 180, "o": True}], nights(lee, plain)
    assert get_team(lee, plain).get("note") == "Flasks on"
    # Undo takes a change back; leaving the team closes the editor
    bob.eval("ns.RaidPlanUI:OpenNightsEditor()")
    w.tick(0.3)
    bob.eval("ns.RaidPlanUI:ToggleDraftNight(1)")
    assert shown(bob, D + ".revertBtn")
    bob.click(bob.eval("return %s.revertBtn" % D))
    w.tick(0.3)
    assert len(lst(bob.eval_py("return ns.RaidPlanUI:GetDraft().nights"))) == 1
    bob.eval("ns.RaidPlanUI:ShowTeamBoard()")
    w.tick(0.3)
    assert not shown(bob, TV + ".nightsPanel")
    # ... > Raid nights opens it too
    bob.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)
    bob.click(bob.eval("return %s.moreBtn" % D))
    hit = [e.get("text") for e in bob.last_menu()["children"]
           if strip_codes(e.get("text") or "").strip() == "Raid nights"]
    bob.menu_select(hit[0])
    w.tick(0.5)
    assert shown(bob, TV + ".nightsPanel") and text(bob, rows + "[1].day") == "Thursday"
    bob.eval("%s.nightsPanel:Hide()" % TV)
    # someone not on the roster: the nights above Join in the waitlist panel
    open_teams(w, rita, tid)
    rita.click(rita.eval("return %s.wlBtn" % D))
    w.tick(0.3)
    assert shown(rita, D + ".wl.nt") and shown(rita, D + ".wl.join")
    assert text(rita, D + ".wl.nt.days") == "Thu + Sun"
    assert text(rita, D + ".wl.nt.note") == '"' + NOTE + '"'
    # a roster member doesn't get it there
    open_teams(w, lee, tid)
    if shown(lee, D + ".wlBtn"):
        lee.click(lee.eval("return %s.wlBtn" % D))
        assert not shown(lee, D + ".wl.nt")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
